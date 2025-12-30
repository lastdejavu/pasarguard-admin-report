#!/usr/bin/env bash
set -euo pipefail

APP_NAME="pasarguard-admin-report"
INSTALL_DIR="/opt/pasarguard-admin-report"
PASARGUARD_ENV="/opt/pasarguard/.env"
LOG_FILE="/var/log/pasarguard-admin-report.log"

DEFAULT_TZ="Asia/Tehran"
CRON_TIME="0 0 * * *"  # 00:00 every day

# ----------------------------
# helpers
# ----------------------------
info(){ echo -e "ℹ️  $*"; }
ok(){ echo -e "✅ $*"; }
warn(){ echo -e "⚠️  $*" >&2; }
die(){ echo -e "❌ $*" >&2; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Please run as root: sudo bash install.sh  (or one-line curl | sudo bash)"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

read_env_value() {
  # read_env_value KEY /path/to/.env
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 0
  # keep everything after first '=' (supports passwords with special chars)
  local line
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 || true)"
  [[ -n "$line" ]] || return 0
  echo "${line#*=}"
}

prompt_default() {
  # prompt_default "Label" "default"
  local label="$1" def="$2"
  local ans
  read -r -p "${label} (default: ${def}): " ans || true
  if [[ -z "${ans// }" ]]; then echo "$def"; else echo "$ans"; fi
}

prompt_secret() {
  # prompt_secret "Label"
  local label="$1"
  local ans
  read -r -s -p "${label}: " ans || true
  echo
  echo "$ans"
}

validate_bot_token() {
  local token="$1"
  # returns bot username or empty
  local resp
  resp="$(curl -fsS "https://api.telegram.org/bot${token}/getMe" 2>/dev/null || true)"
  echo "$resp" | grep -q '"ok":true' || return 1
  # extract username roughly without jq
  echo "$resp" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p' | head -n1
}

send_test_message() {
  local token="$1" chat="$2" text="$3"
  curl -fsS -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -d "chat_id=${chat}" \
    -d "text=${text}" \
    -d "disable_web_page_preview=true" >/dev/null
}

detect_mysql_container() {
  # prefer common name
  if docker ps --format '{{.Names}}' | grep -qx "pasarguard-mysql-1"; then
    echo "pasarguard-mysql-1"
    return
  fi
  # otherwise: first container whose image contains mysql and running
  local c
  c="$(docker ps --format '{{.Names}}\t{{.Image}}' | awk '$2 ~ /mysql/i {print $1; exit}')"
  if [[ -n "$c" ]]; then
    echo "$c"
    return
  fi
  echo ""
}

install_packages() {
  info "Installing packages (python3, venv, pip, cron, curl)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y python3 python3-venv python3-pip cron curl >/dev/null
  ok "Packages installed."
}

write_requirements() {
  cat > "${INSTALL_DIR}/requirements.txt" <<'REQ'
pymysql==1.1.2
requests==2.32.5
jdatetime==5.2.0
python-dotenv==1.0.1
REQ
}

write_triggers_sql() {
  cat > "${INSTALL_DIR}/triggers.sql" <<'SQL'
-- PasarGuard Admin Report triggers (MySQL 8+)
-- Creates:
--   - admin_report_events table (with reported_at to avoid duplicate reporting)
--   - triggers on users: create + limit change + limit->unlimited + unlimited->limit + usage reset

USE pasarguard;

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
  reported_at TIMESTAMP NULL DEFAULT NULL,

  INDEX idx_created_at (created_at),
  INDEX idx_reported_at (reported_at),
  INDEX idx_admin_created (admin_id, created_at),
  INDEX idx_admin_reported (admin_id, reported_at)
);

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
  -- limited -> unlimited
  IF (OLD.data_limit IS NOT NULL AND NEW.data_limit IS NULL) THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, old_data_limit, new_data_limit, old_used, new_used)
    VALUES ('LIMIT_TO_UNLIMITED', NEW.admin_id, NEW.id, NEW.username, OLD.data_limit, NEW.data_limit, OLD.used_traffic, NEW.used_traffic);

  -- unlimited -> limited (usually not a loss; still recorded for audit)
  ELSEIF (OLD.data_limit IS NULL AND NEW.data_limit IS NOT NULL) THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, old_data_limit, new_data_limit, old_used, new_used)
    VALUES ('UNLIMITED_TO_LIMIT', NEW.admin_id, NEW.id, NEW.username, OLD.data_limit, NEW.data_limit, OLD.used_traffic, NEW.used_traffic);

  -- limited -> limited (volume change)
  ELSEIF (OLD.data_limit IS NOT NULL AND NEW.data_limit IS NOT NULL AND OLD.data_limit <> NEW.data_limit) THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, old_data_limit, new_data_limit, old_used, new_used)
    VALUES ('DATA_LIMIT_CHANGED', NEW.admin_id, NEW.id, NEW.username, OLD.data_limit, NEW.data_limit, OLD.used_traffic, NEW.used_traffic);
  END IF;

  -- usage reset (any decrease)
  IF (OLD.used_traffic > NEW.used_traffic) THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, old_used, new_used)
    VALUES ('USAGE_RESET', NEW.admin_id, NEW.id, NEW.username, OLD.used_traffic, NEW.used_traffic);
  END IF;
END $$

DELIMITER ;
SQL
}

write_daily_digest_py() {
  cat > "${INSTALL_DIR}/daily_digest.py" <<'PY'
import os, time
import pymysql
import requests
import jdatetime
from dotenv import load_dotenv
from datetime import datetime, timedelta
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

INCLUDE_RESETS = os.getenv("INCLUDE_RESETS", "1") == "1"
SHOW_LIMIT_AFTER_UNLIMITED = os.getenv("SHOW_LIMIT_AFTER_UNLIMITED", "1") == "1"

def send(text: str) -> None:
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
    r = requests.post(url, data={
        "chat_id": CHAT_ID,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": "true",
    }, timeout=20)
    r.raise_for_status()

def gb_from_bytes(n: int) -> float:
    return n / (1024**3)

def fmt_gb(n_gb: float) -> str:
    return f"{n_gb:.2f} GB"

def _range_tehran(mode: str):
    now = datetime.now(TZ)
    start_today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    if mode == "today":
        return start_today, now
    # default: yesterday [00:00, 00:00)
    start_yesterday = start_today - timedelta(days=1)
    return start_yesterday, start_today

def jalali_date_str(greg_date):
    j = jdatetime.date.fromgregorian(date=greg_date)
    return f"{j.year:04d}-{j.month:02d}-{j.day:02d}"

def connect():
    return pymysql.connect(
        host=MYSQL_HOST, port=MYSQL_PORT,
        user=MYSQL_USER, password=MYSQL_PASSWORD,
        database=MYSQL_DATABASE,
        cursorclass=pymysql.cursors.DictCursor,
        connect_timeout=10,
        autocommit=True
    )

def fetch_events(start_dt, end_dt, override: bool):
    # reported_at logic: if override=False only fetch unreported rows
    cond = "" if override else "AND e.reported_at IS NULL"
    q = f"""
        SELECT
            e.id, e.event_type, e.admin_id,
            a.username AS admin_username,
            e.user_id, e.username,
            e.old_data_limit, e.new_data_limit,
            e.old_used, e.new_used,
            e.created_at
        FROM admin_report_events e
        LEFT JOIN admins a ON a.id = e.admin_id
        WHERE e.created_at >= %s AND e.created_at < %s
        {cond}
        ORDER BY e.admin_id ASC, e.id ASC
    """
    conn = connect()
    try:
        with conn.cursor() as cur:
            cur.execute(q, (start_dt.replace(tzinfo=None), end_dt.replace(tzinfo=None)))
            return cur.fetchall()
    finally:
        conn.close()

def mark_reported(ids):
    if not ids:
        return
    conn = connect()
    try:
        with conn.cursor() as cur:
            # chunk to avoid very large IN()
            CHUNK = 500
            for i in range(0, len(ids), CHUNK):
                part = ids[i:i+CHUNK]
                placeholders = ",".join(["%s"] * len(part))
                cur.execute(f"UPDATE admin_report_events SET reported_at = NOW() WHERE id IN ({placeholders})", part)
    finally:
        conn.close()

def build_messages(rows):
    # only these affect “loss risk” / reporting
    allowed = {"USER_CREATED", "DATA_LIMIT_CHANGED", "UNLIMITED_CREATED", "LIMIT_TO_UNLIMITED"}
    if INCLUDE_RESETS:
        allowed.add("USAGE_RESET")

    rows = [r for r in rows if r.get("event_type") in allowed]

    by_admin = {}
    for r in rows:
        by_admin.setdefault(r.get("admin_id") or 0, []).append(r)

    messages = []  # list of (admin_id, text, used_event_ids)
    for admin_id, evs in by_admin.items():
        admin_name = evs[0].get("admin_username") or f"admin_id={admin_id}"

        user_state = {}  # username -> dict
        used_ids = []

        for e in evs:
            used_ids.append(int(e["id"]))
            u = e.get("username") or f"user_id={e.get('user_id')}"
            st = user_state.setdefault(u, {"unlimited": False, "was_limit_bytes": None, "delta_bytes": 0, "reset": False})

            t = e["event_type"]

            if t == "UNLIMITED_CREATED":
                st["unlimited"] = True
                continue

            if t == "LIMIT_TO_UNLIMITED":
                st["unlimited"] = True
                oldv = e.get("old_data_limit")
                if oldv is not None:
                    st["was_limit_bytes"] = int(oldv)
                continue

            if t == "USER_CREATED":
                if e.get("new_data_limit") is None:
                    st["unlimited"] = True
                else:
                    st["delta_bytes"] += int(e["new_data_limit"])
                continue

            if t == "DATA_LIMIT_CHANGED":
                oldv = e.get("old_data_limit")
                newv = e.get("new_data_limit")
                if oldv is None or newv is None:
                    # conversions are handled by LIMIT_TO_UNLIMITED/UNLIMITED_TO_LIMIT triggers
                    continue
                delta = int(newv) - int(oldv)
                # فقط افزایش‌ها را گزارش کن (کاهش ضرر نیست)
                if delta > 0:
                    st["delta_bytes"] += delta
                continue

            if t == "USAGE_RESET":
                st["reset"] = True
                continue

        # message header date = based on first event day (digest range day)
        # we'll fill date later from caller; here just return body
        # We'll add date placeholder "{DATE}"
        lines = [f"<b>{{DATE}}</b>", f"Admin: <b>{admin_name}</b>", ""]

        total_pos_gb = 0.0
        has_any = False

        for u in sorted(user_state.keys()):
            st = user_state[u]

            suffix = ""
            if INCLUDE_RESETS and st["reset"]:
                suffix = " | reset"

            if st["unlimited"]:
                if SHOW_LIMIT_AFTER_UNLIMITED and st["was_limit_bytes"] is not None:
                    was_gb = gb_from_bytes(st["was_limit_bytes"])
                    lines.append(f"- {u}: unlimited (was {fmt_gb(was_gb)}){suffix}")
                else:
                    lines.append(f"- {u}: unlimited{suffix}")
                has_any = True
                continue

            delta = st["delta_bytes"]
            if delta > 0:
                g = gb_from_bytes(delta)
                total_pos_gb += g
                lines.append(f"- {u}: +{fmt_gb(g)}{suffix}")
                has_any = True
            else:
                # only reset with no delta
                if INCLUDE_RESETS and st["reset"]:
                    lines.append(f"- {u}: reset")
                    has_any = True

        if not has_any:
            continue

        lines.append("")
        lines.append(f"Total: <b>{fmt_gb(total_pos_gb)}</b>")

        messages.append((admin_id, "\n".join(lines), used_ids))

    return messages

def main():
    import sys

    if not BOT_TOKEN or not CHAT_ID:
        raise SystemExit("Missing TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID in .env")

    mode = "yesterday"
    override = False
    dry_run = False

    args = sys.argv[1:]
    for a in args:
        if a in ("today", "yesterday"):
            mode = a
        elif a in ("--override", "override"):
            override = True
        elif a in ("--dry-run", "dry"):
            dry_run = True

    start_dt, end_dt = _range_tehran(mode)
    jalali = jalali_date_str(start_dt.date())

    rows = fetch_events(start_dt, end_dt, override=override)
    msgs = build_messages(rows)

    if not msgs:
        return

    for _admin_id, text, ids in msgs:
        text = text.replace("{DATE}", jalali)
        if dry_run:
            print(text)
        else:
            send(text)
            time.sleep(0.4)
            # mark as reported only if not override
            if not override:
                mark_reported(ids)

if __name__ == "__main__":
    main()
PY
}

write_app_env() {
  local tz="$1" token="$2" chat="$3" host="$4" port="$5" db="$6" user="$7" pass="$8"
  cat > "${INSTALL_DIR}/.env" <<EOF
# ${APP_NAME} config
TIMEZONE=${tz}

# Telegram
TELEGRAM_BOT_TOKEN=${token}
TELEGRAM_CHAT_ID=${chat}

# MySQL (PasarGuard database)
MYSQL_HOST=${host}
MYSQL_PORT=${port}
MYSQL_DATABASE=${db}
MYSQL_USER=${user}
MYSQL_PASSWORD=${pass}

# Report options
INCLUDE_RESETS=1
SHOW_LIMIT_AFTER_UNLIMITED=1
EOF
  chmod 600 "${INSTALL_DIR}/.env"
}

create_venv() {
  info "Creating Python venv..."
  python3 -m venv "${INSTALL_DIR}/.venv"
  "${INSTALL_DIR}/.venv/bin/python" -m pip install --upgrade pip >/dev/null
  "${INSTALL_DIR}/.venv/bin/pip" install -r "${INSTALL_DIR}/requirements.txt" >/dev/null
  ok "Python deps installed."
}

apply_triggers() {
  local container="$1" root_pass="$2" db_name="$3"
  info "Applying triggers inside MySQL container: ${container} (db: ${db_name})"
  # Use MYSQL_PWD env to avoid showing password in commandline history
  docker exec -i -e MYSQL_PWD="${root_pass}" "${container}" mysql -uroot < "${INSTALL_DIR}/triggers.sql"
  # verify
  local out
  out="$(docker exec -i -e MYSQL_PWD="${root_pass}" "${container}" mysql -uroot -N -B -e "USE \`${db_name}\`; SHOW TRIGGERS;" 2>/dev/null || true)"
  echo "$out" | grep -q "trg_report_user_create" || die "Triggers not found after apply."
  ok "Triggers applied."
}

install_cron() {
  info "Installing cron (daily 00:00 ${DEFAULT_TZ})..."
  local tmp
  tmp="$(mktemp)"
  # keep existing cron, remove our block if exists
  (crontab -l 2>/dev/null || true) | sed '/BEGIN pasarguard-admin-report/,/END pasarguard-admin-report/d' > "$tmp"
  {
    echo "# BEGIN pasarguard-admin-report"
    echo "${CRON_TIME} TZ=${DEFAULT_TZ} ${INSTALL_DIR}/.venv/bin/python ${INSTALL_DIR}/daily_digest.py >> ${LOG_FILE} 2>&1"
    echo "# END pasarguard-admin-report"
  } >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  ok "Cron installed."
}

# ----------------------------
# main
# ----------------------------
need_root
require_cmd apt-get
require_cmd curl
require_cmd docker

echo "======================================"
echo "✅ ${APP_NAME} one-line installer"
echo "======================================"

install_packages

[[ -f "${PASARGUARD_ENV}" ]] || die "PasarGuard env not found: ${PASARGUARD_ENV}"

info "Found PasarGuard env: ${PASARGUARD_ENV}"

MYSQL_ROOT_PASSWORD="$(read_env_value MYSQL_ROOT_PASSWORD "${PASARGUARD_ENV}")"
[[ -n "${MYSQL_ROOT_PASSWORD}" ]] || die "MYSQL_ROOT_PASSWORD not found in ${PASARGUARD_ENV}"

DB_NAME="$(read_env_value DB_NAME "${PASARGUARD_ENV}")"
[[ -n "${DB_NAME}" ]] || DB_NAME="pasarguard"

DB_HOST="$(read_env_value DB_HOST "${PASARGUARD_ENV}")"
DB_PORT="$(read_env_value DB_PORT "${PASARGUARD_ENV}")"
DB_USER="$(read_env_value DB_USER "${PASARGUARD_ENV}")"
DB_PASS="$(read_env_value DB_PASS "${PASARGUARD_ENV}")"

# Fall back to common keys if panel uses different naming
[[ -n "${DB_USER}" ]] || DB_USER="$(read_env_value MYSQL_USER "${PASARGUARD_ENV}")"
[[ -n "${DB_PASS}" ]] || DB_PASS="$(read_env_value MYSQL_PASSWORD "${PASARGUARD_ENV}")"

[[ -n "${DB_HOST}" ]] || DB_HOST="127.0.0.1"
[[ -n "${DB_PORT}" ]] || DB_PORT="3306"

CONTAINER="$(detect_mysql_container)"
if [[ -z "${CONTAINER}" ]]; then
  warn "Could not auto-detect MySQL container."
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}"
  read -r -p "Enter MySQL container name: " CONTAINER
  [[ -n "${CONTAINER}" ]] || die "No container provided."
fi
info "Detected MySQL container: ${CONTAINER}"

# Create folder
mkdir -p "${INSTALL_DIR}"

# Ask for timezone + telegram
TZ="$(prompt_default "Timezone" "${DEFAULT_TZ}")"

# Telegram token loop with validation
BOT_TOKEN=""
BOT_USER=""
while true; do
  read -r -p "Telegram Bot Token: " BOT_TOKEN || true
  BOT_TOKEN="${BOT_TOKEN//[[:space:]]/}"   # remove whitespace
  [[ -n "${BOT_TOKEN}" ]] || { warn "Token cannot be empty."; continue; }
  BOT_USER="$(validate_bot_token "${BOT_TOKEN}" || true)"
  if [[ -n "${BOT_USER}" ]]; then
    ok "Bot token is valid. Bot username: @${BOT_USER}"
    # show token back (requested) — but still warn:
    warn "Your Bot Token (keep it secret): ${BOT_TOKEN}"
    break
  fi
  warn "Invalid Bot Token (getMe failed). Please paste again."
done

CHAT_ID="$(prompt_default "Telegram Chat ID" "")"
[[ -n "${CHAT_ID// }" ]] || die "Chat ID cannot be empty."

# MySQL app credentials (for reading events)
if [[ -z "${DB_USER}" || -z "${DB_PASS}" ]]; then
  warn "DB_USER/DB_PASS not found in ${PASARGUARD_ENV}."
  DB_USER="$(prompt_default "MySQL Username" "pasarguard")"
  DB_PASS="$(prompt_secret "MySQL Password")"
  [[ -n "${DB_PASS}" ]] || die "MySQL password cannot be empty."
fi

# Write files (self-contained install)
write_requirements
write_triggers_sql
write_daily_digest_py
write_app_env "${TZ}" "${BOT_TOKEN}" "${CHAT_ID}" "${DB_HOST}" "${DB_PORT}" "${DB_NAME}" "${DB_USER}" "${DB_PASS}"

create_venv
apply_triggers "${CONTAINER}" "${MYSQL_ROOT_PASSWORD}" "${DB_NAME}"
install_cron

# create log file so tail works
touch "${LOG_FILE}"
chmod 600 "${LOG_FILE}"

# Send install confirmation message (optional but helpful)
info "Sending a test message to Telegram..."
if send_test_message "${BOT_TOKEN}" "${CHAT_ID}" "✅ PasarGuard Admin Report installed.\nDaily digest scheduled at 00:00 (${TZ})."; then
  ok "Telegram test message sent."
else
  warn "Could not send test message. Please check chat_id and bot permissions."
fi

ok "Installed!"
info "Files: ${INSTALL_DIR}"
info "Log:   ${LOG_FILE}"
echo
info "Test now (prints nothing if no events):"
echo "  ${INSTALL_DIR}/.venv/bin/python ${INSTALL_DIR}/daily_digest.py today --override"
echo
info "Config:"
echo "  ${INSTALL_DIR}/.env"
