#!/usr/bin/env bash
set -euo pipefail

APP_NAME="pasarguard-admin-report"
INSTALL_DIR="/opt/pasarguard-admin-report"
LOG_FILE="/var/log/pasarguard-admin-report.log"

# ---------- UI helpers ----------
ok()    { echo -e "✅ $*"; }
info()  { echo -e "ℹ️  $*"; }
warn()  { echo -e "⚠️  $*"; }
err()   { echo -e "❌ $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Please run as root: sudo bash install.sh"
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

prompt() {
  # prompt VAR "Text" "default" secret(0/1)
  local var="$1"
  local text="$2"
  local def="${3:-}"
  local secret="${4:-0}"
  local val=""

  if [[ "$secret" == "1" ]]; then
    read -r -s -p "${text}${def:+ (default: ${def})}: " val
    echo
  else
    read -r -p "${text}${def:+ (default: ${def})}: " val
  fi

  if [[ -z "${val:-}" ]]; then
    val="$def"
  fi
  printf -v "$var" '%s' "$val"
}

get_env_value() {
  # get_env_value FILE KEY
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 1
  # Supports KEY=value and KEY="value"
  local line
  line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n 1 || true)"
  [[ -n "$line" ]] || return 1
  line="${line#*=}"
  line="${line%$'\r'}"
  # strip quotes
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  echo -n "$line"
}

detect_mysql_container() {
  # Prefer known default
  if docker ps --format '{{.Names}}' | grep -qx 'pasarguard-mysql-1'; then
    echo -n 'pasarguard-mysql-1'; return 0
  fi
  # docker compose label
  local c
  c="$(docker ps --filter 'label=com.docker.compose.service=mysql' --format '{{.Names}}' | head -n1 || true)"
  if [[ -n "${c:-}" ]]; then
    echo -n "$c"; return 0
  fi
  # fallback: first mysql image
  c="$(docker ps --format '{{.Names}}\t{{.Image}}' | awk '$2 ~ /^mysql(:|$)/ {print $1; exit}')"
  if [[ -n "${c:-}" ]]; then
    echo -n "$c"; return 0
  fi
  return 1
}

install_packages() {
  info "Installing packages (python3, venv, cron, curl)..."
  apt-get update -y >/dev/null
  apt-get install -y python3 python3-venv python3-pip cron curl ca-certificates >/dev/null
  ok "Packages installed."
  if ! have_cmd docker; then
    err "docker not found. Please install Docker and make sure PasarGuard is running."
    exit 1
  fi
}

write_requirements() {
  cat > "$INSTALL_DIR/requirements.txt" <<'REQ'
pymysql==1.1.2
requests==2.32.5
jdatetime==5.2.0
python-dotenv==1.2.1
REQ
}

write_triggers_sql() {
  # Important: no USE statement; we run mysql with DB already selected.
  cat > "$INSTALL_DIR/triggers.sql" <<'SQL'
-- PasarGuard Admin Report Triggers (MySQL)
-- Run inside the PasarGuard MySQL container (root recommended).

CREATE TABLE IF NOT EXISTS admin_report_events (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  event_type VARCHAR(64) NOT NULL,
  admin_id BIGINT NULL,
  user_id BIGINT NULL,
  username VARCHAR(255) NULL,
  old_data_limit BIGINT NULL,
  new_data_limit BIGINT NULL,
  old_used BIGINT NULL,
  new_used BIGINT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_created_at (created_at),
  INDEX idx_admin_created (admin_id, created_at),
  INDEX idx_username_created (username, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

DELIMITER $$

DROP TRIGGER IF EXISTS trg_report_user_create $$
CREATE TRIGGER trg_report_user_create
AFTER INSERT ON users
FOR EACH ROW
BEGIN
  IF NEW.data_limit IS NULL THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, new_data_limit, new_used)
    VALUES ('UNLIMITED_CREATED', NEW.admin_id, NEW.id, NEW.username, NEW.data_limit, NEW.used_traffic);
  ELSE
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, new_data_limit, new_used)
    VALUES ('USER_CREATED', NEW.admin_id, NEW.id, NEW.username, NEW.data_limit, NEW.used_traffic);
  END IF;
END $$

DROP TRIGGER IF EXISTS trg_report_user_update $$
CREATE TRIGGER trg_report_user_update
AFTER UPDATE ON users
FOR EACH ROW
BEGIN
  -- limit -> unlimited (important for loss prevention)
  IF (OLD.data_limit IS NOT NULL AND NEW.data_limit IS NULL) THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, old_data_limit, new_data_limit, old_used, new_used)
    VALUES ('LIMIT_TO_UNLIMITED', NEW.admin_id, NEW.id, NEW.username, OLD.data_limit, NEW.data_limit, OLD.used_traffic, NEW.used_traffic);

  -- unlimited -> limit (stored for completeness; digest can ignore if you want)
  ELSEIF (OLD.data_limit IS NULL AND NEW.data_limit IS NOT NULL) THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, old_data_limit, new_data_limit, old_used, new_used)
    VALUES ('UNLIMITED_TO_LIMIT', NEW.admin_id, NEW.id, NEW.username, OLD.data_limit, NEW.data_limit, OLD.used_traffic, NEW.used_traffic);

  -- limit change (increase/decrease)
  ELSEIF (OLD.data_limit IS NOT NULL AND NEW.data_limit IS NOT NULL AND OLD.data_limit <> NEW.data_limit) THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, old_data_limit, new_data_limit, old_used, new_used)
    VALUES ('DATA_LIMIT_CHANGED', NEW.admin_id, NEW.id, NEW.username, OLD.data_limit, NEW.data_limit, OLD.used_traffic, NEW.used_traffic);
  END IF;

  -- usage reset (optional in digest)
  IF (OLD.used_traffic > NEW.used_traffic) THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, old_used, new_used)
    VALUES ('USAGE_RESET', NEW.admin_id, NEW.id, NEW.username, OLD.used_traffic, NEW.used_traffic);
  END IF;
END $$

DELIMITER ;
SQL
}

write_daily_digest() {
  cat > "$INSTALL_DIR/daily_digest.py" <<'PY'
import os, time
import pymysql
import requests
import jdatetime
from dotenv import load_dotenv
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

ENV_PATH = "/opt/pasarguard-admin-report/.env"
load_dotenv(ENV_PATH)

TZ = ZoneInfo(os.getenv("TIMEZONE", "Asia/Tehran"))

MYSQL_HOST = os.getenv("MYSQL_HOST", "127.0.0.1")
MYSQL_PORT = int(os.getenv("MYSQL_PORT", "3306"))
MYSQL_USER = os.getenv("MYSQL_USER")
MYSQL_PASSWORD = os.getenv("MYSQL_PASSWORD")
MYSQL_DATABASE = os.getenv("MYSQL_DATABASE", "pasarguard")

BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
CHAT_ID = os.getenv("TELEGRAM_CHAT_ID")

# optional (0/1). default off to avoid noise
INCLUDE_RESETS = os.getenv("REPORT_INCLUDE_RESETS", "0").strip() == "1"

def send(text: str) -> None:
  url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
  r = requests.post(
    url,
    data={"chat_id": CHAT_ID, "text": text, "disable_web_page_preview": "true"},
    timeout=20,
  )
  r.raise_for_status()

def gb_from_bytes(n: int) -> float:
  return n / (1024**3)

def fmt_gb(n_gb: float) -> str:
  return f"{n_gb:.2f} GB"

def tehran_yesterday_range_as_utc_naive():
  """
  We want 'yesterday' in Asia/Tehran.
  MySQL TIMESTAMP is usually stored as UTC.
  Convert Tehran range to UTC naive for query compatibility.
  """
  now_tz = datetime.now(TZ)
  start_today_tz = now_tz.replace(hour=0, minute=0, second=0, microsecond=0)
  start_yesterday_tz = start_today_tz - timedelta(days=1)

  start_utc = start_yesterday_tz.astimezone(timezone.utc).replace(tzinfo=None)
  end_utc = start_today_tz.astimezone(timezone.utc).replace(tzinfo=None)
  return start_yesterday_tz.date(), start_utc, end_utc

def fetch_events(start_utc_naive, end_utc_naive):
  conn = pymysql.connect(
    host=MYSQL_HOST,
    port=MYSQL_PORT,
    user=MYSQL_USER,
    password=MYSQL_PASSWORD,
    database=MYSQL_DATABASE,
    cursorclass=pymysql.cursors.DictCursor,
    connect_timeout=10,
    autocommit=True,
  )
  try:
    with conn.cursor() as cur:
      cur.execute(
        """
        SELECT
          e.id, e.event_type, e.admin_id,
          a.username AS admin_username,
          e.user_id, e.username,
          e.old_data_limit, e.new_data_limit,
          e.old_used, e.new_used
        FROM admin_report_events e
        LEFT JOIN admins a ON a.id = e.admin_id
        WHERE e.created_at >= %s AND e.created_at < %s
        ORDER BY e.admin_id ASC, e.id ASC
        """,
        (start_utc_naive, end_utc_naive),
      )
      return cur.fetchall()
  finally:
    conn.close()

def main():
  if not BOT_TOKEN or not CHAT_ID:
    raise SystemExit("Missing TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID in /opt/pasarguard-admin-report/.env")

  g_date, start_utc, end_utc = tehran_yesterday_range_as_utc_naive()
  j = jdatetime.date.fromgregorian(date=g_date)
  jalali_str = f"{j.year:04d}-{j.month:02d}-{j.day:02d}"

  rows = fetch_events(start_utc, end_utc)

  allowed = {
    "USER_CREATED",
    "DATA_LIMIT_CHANGED",
    "UNLIMITED_CREATED",
    "LIMIT_TO_UNLIMITED",
    "UNLIMITED_TO_LIMIT",
    "USAGE_RESET",
  }
  rows = [r for r in rows if r.get("event_type") in allowed]

  by_admin = {}
  for r in rows:
    by_admin.setdefault(r.get("admin_id") or 0, []).append(r)

  if not by_admin:
    return

  for admin_id, evs in by_admin.items():
    admin_name = evs[0].get("admin_username") or f"admin_id={admin_id}"

    # If a user becomes unlimited and then returns to limit in the same day,
    # we do NOT show unlimited (avoids confusing output).
    user_state = {}  # username -> dict
    resets = set()

    for e in evs:
      u = e.get("username") or f"user_id={e.get('user_id')}"
      st = user_state.setdefault(
        u,
        {"unlimited": False, "unlimited_was": None, "unlimited_canceled": False, "delta_bytes": 0},
      )

      t = e["event_type"]

      if t == "USAGE_RESET":
        resets.add(u)
        continue

      if t == "UNLIMITED_CREATED":
        st["unlimited"] = True
        st["unlimited_was"] = None
        continue

      if t == "LIMIT_TO_UNLIMITED":
        st["unlimited"] = True
        oldv = e.get("old_data_limit")
        if oldv is not None:
          st["unlimited_was"] = int(oldv)
        continue

      if t == "UNLIMITED_TO_LIMIT":
        st["unlimited"] = False
        st["unlimited_canceled"] = True
        continue

      if t == "USER_CREATED":
        newv = e.get("new_data_limit")
        if newv is None:
          st["unlimited"] = True
        else:
          st["delta_bytes"] += int(newv)
        continue

      if t == "DATA_LIMIT_CHANGED":
        oldv = e.get("old_data_limit")
        newv = e.get("new_data_limit")
        if oldv is None or newv is None:
          if newv is None:
            st["unlimited"] = True
            st["unlimited_was"] = int(oldv) if oldv is not None else None
          continue
        st["delta_bytes"] += int(newv) - int(oldv)
        continue

    lines = [jalali_str, f"Admin: {admin_name}", ""]
    user_lines = []
    total_pos_gb = 0.0

    for u in sorted(user_state.keys()):
      st = user_state[u]

      if st["unlimited"] and not st["unlimited_canceled"]:
        if st["unlimited_was"] is not None:
          user_lines.append(f"- {u}: unlimited (was {fmt_gb(gb_from_bytes(st['unlimited_was']))})")
        else:
          user_lines.append(f"- {u}: unlimited")
        continue

      delta = st["delta_bytes"]
      if delta > 0:
        g = gb_from_bytes(delta)
        total_pos_gb += g
        user_lines.append(f"- {u}: +{fmt_gb(g)}")

    if not user_lines and not (INCLUDE_RESETS and resets):
      continue

    lines.extend(user_lines)

    if user_lines:
      lines.append("")
      lines.append(f"Total: {fmt_gb(total_pos_gb)}")

    if INCLUDE_RESETS and resets:
      lines.append("")
      lines.append("Resets: " + ", ".join(sorted(resets)))

    send("\n".join(lines))
    time.sleep(0.5)

if __name__ == "__main__":
  main()
PY
}

setup_env_file() {
  local tz="$1"
  local bot="$2"
  local chat="$3"
  local db_name="$4"
  local mysql_host="$5"
  local mysql_port="$6"
  local mysql_user="$7"
  local mysql_pass="$8"

  cat > "$INSTALL_DIR/.env" <<EOF
# ${APP_NAME}
TIMEZONE=${tz}

# Telegram
TELEGRAM_BOT_TOKEN=${bot}
TELEGRAM_CHAT_ID=${chat}

# MySQL (PasarGuard)
MYSQL_HOST=${mysql_host}
MYSQL_PORT=${mysql_port}
MYSQL_USER=${mysql_user}
MYSQL_PASSWORD=${mysql_pass}
MYSQL_DATABASE=${db_name}

# Optional: include resets in digest (0/1). Default 0 (no noise).
REPORT_INCLUDE_RESETS=0
EOF
  chmod 600 "$INSTALL_DIR/.env"
}

setup_venv() {
  info "Creating Python venv..."
  python3 -m venv "$INSTALL_DIR/.venv"
  "$INSTALL_DIR/.venv/bin/pip" install -U pip >/dev/null
  "$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" >/dev/null
  ok "Python deps installed."
}

apply_triggers_in_docker() {
  local container="$1"
  local root_password="$2"
  local db="$3"

  info "Applying triggers inside MySQL container: ${container} (db: ${db})"
  docker exec -i "$container" mysql -uroot -p"$root_password" "$db" < "$INSTALL_DIR/triggers.sql" >/dev/null
  ok "Triggers applied."
}

install_cron() {
  local tz="$1"
  local marker_begin="# BEGIN ${APP_NAME}"
  local marker_end="# END ${APP_NAME}"
  local cron_line="0 0 * * * TZ=${tz} ${INSTALL_DIR}/.venv/bin/python ${INSTALL_DIR}/daily_digest.py >> ${LOG_FILE} 2>&1"

  info "Installing cron (daily 00:00 ${tz})..."
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null > "$tmp" || true

  # Remove previous block
  awk -v b="$marker_begin" -v e="$marker_end" '
    $0==b {inblock=1; next}
    $0==e {inblock=0; next}
    !inblock {print}
  ' "$tmp" > "${tmp}.clean"

  {
    cat "${tmp}.clean"
    echo "$marker_begin"
    echo "$cron_line"
    echo "$marker_end"
  } > "$tmp"

  crontab "$tmp"
  rm -f "$tmp" "${tmp}.clean"
  ok "Cron installed."
}

main() {
  need_root

  echo "======================================"
  echo "✅ ${APP_NAME} one-line installer"
  echo "======================================"

  install_packages

  mkdir -p "$INSTALL_DIR"

  # Read PasarGuard env (docker MySQL)
  local pg_env="/opt/pasarguard/.env"
  local db_name="pasarguard"
  local db_user="pasarguard"
  local db_pass=""
  local root_pass=""
  local mysql_host="127.0.0.1"
  local mysql_port="3306"

  if [[ -f "$pg_env" ]]; then
    info "Found PasarGuard env: $pg_env"
    db_name="$(get_env_value "$pg_env" "DB_NAME" || echo "pasarguard")"
    db_user="$(get_env_value "$pg_env" "DB_USER" || echo "pasarguard")"
    db_pass="$(get_env_value "$pg_env" "DB_PASSWORD" || echo "")"
    root_pass="$(get_env_value "$pg_env" "MYSQL_ROOT_PASSWORD" || echo "")"
  else
    warn "PasarGuard env not found at /opt/pasarguard/.env (you can still install, but you must enter MySQL passwords)."
  fi

  # Detect MySQL docker container
  local container=""
  if container="$(detect_mysql_container 2>/dev/null)"; then
    info "Detected MySQL container: $container"
  else
    container=""
  fi

  # Ask Telegram + missing values
  local timezone_val="Asia/Tehran"
  prompt timezone_val "Timezone" "${TIMEZONE:-Asia/Tehran}"

  local tg_bot="${TELEGRAM_BOT_TOKEN:-}"
  if [[ -z "${tg_bot:-}" ]]; then
    prompt tg_bot "Telegram Bot Token" "" 1
  fi

  local tg_chat="${TELEGRAM_CHAT_ID:-}"
  if [[ -z "${tg_chat:-}" ]]; then
    prompt tg_chat "Telegram Chat ID" ""
  fi

  if [[ -z "${container:-}" ]]; then
    prompt container "MySQL docker container name" "pasarguard-mysql-1"
  fi

  if [[ -z "${root_pass:-}" ]]; then
    prompt root_pass "MySQL ROOT password (inside container)" "" 1
  else
    prompt root_pass "MySQL ROOT password (inside container)" "${root_pass}" 1
  fi

  # Validate container exists
  if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
    err "Container not running: $container"
    info "Run: docker ps"
    exit 1
  fi

  # Ensure DB creds exist for reporter (connects via host port 3306 on server)
  # Most PasarGuard setups expose 3306 to localhost. If not, user can change MYSQL_HOST/PORT later in /opt/pasarguard-admin-report/.env
  if [[ -z "${db_pass:-}" ]]; then
    prompt db_user "PasarGuard DB user" "${db_user}"
    prompt db_pass "PasarGuard DB password" "" 1
    prompt db_name "PasarGuard DB name" "${db_name}"
  fi

  # Write project files
  write_requirements
  write_triggers_sql
  write_daily_digest

  # Create venv + deps
  setup_venv

  # Apply triggers (root inside container)
  apply_triggers_in_docker "$container" "$root_pass" "$db_name"

  # Create .env for digest
  setup_env_file "$timezone_val" "$tg_bot" "$tg_chat" "$db_name" "$mysql_host" "$mysql_port" "$db_user" "$db_pass"

  # Cron
  install_cron "$timezone_val"

  ok "Installed!"
  info "Files: $INSTALL_DIR"
  info "Log:   $LOG_FILE"
  info "Test now (may send only if yesterday had events):"
  echo "  ${INSTALL_DIR}/.venv/bin/python ${INSTALL_DIR}/daily_digest.py"
  echo
  info "If your MySQL is NOT exposed on 127.0.0.1:3306, edit:"
  echo "  $INSTALL_DIR/.env"
}

main "$@"
