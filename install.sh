#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/pasarguard-admin-report"
PASARGUARD_ENV="/opt/pasarguard/.env"
LOG_FILE="/var/log/pasarguard-admin-report.log"

echo "======================================"
echo "✅ pasarguard-admin-report one-line installer"
echo "======================================"

if [[ "${EUID}" -ne 0 ]]; then
  echo "❌ Please run as root (use sudo)."
  exit 1
fi

need_cmd() { command -v "$1" >/dev/null 2>&1; }
get_env_val() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 1
  # gets value after KEY= (supports values with '=')
  local line
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1 || true)"
  [[ -n "$line" ]] || return 1
  echo "${line#*=}"
}

# Read from tty even if script is piped (so curl|bash works)
prompt() {
  local msg="$1" def="${2:-}"
  local ans=""
  if [[ -n "$def" ]]; then
    read -r -p "$msg (default: $def): " ans </dev/tty || true
    ans="${ans:-$def}"
  else
    read -r -p "$msg: " ans </dev/tty || true
  fi
  echo "$ans"
}

echo "ℹ️  Installing packages (python3, venv, cron, curl)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y python3 python3-venv python3-pip cron curl ca-certificates >/dev/null
echo "✅ Packages installed."

if ! need_cmd docker; then
  echo "❌ docker is not installed or not in PATH."
  echo "➡️ Install docker and ensure PasarGuard is running, then retry."
  exit 1
fi

if [[ ! -f "$PASARGUARD_ENV" ]]; then
  echo "❌ PasarGuard env not found at: $PASARGUARD_ENV"
  echo "➡️ This installer expects PasarGuard installed in /opt/pasarguard"
  exit 1
fi

echo "ℹ️  Found PasarGuard env: $PASARGUARD_ENV"

# Detect MySQL container (default: pasarguard-mysql-1)
MYSQL_CONTAINER="$(docker ps --format '{{.Names}}' | grep -E 'mysql' | grep -E 'pasarguard' | head -n 1 || true)"
if [[ -z "$MYSQL_CONTAINER" ]]; then
  # fallback: any mysql container
  MYSQL_CONTAINER="$(docker ps --format '{{.Names}}' | grep -E 'mysql' | head -n 1 || true)"
fi

if [[ -z "$MYSQL_CONTAINER" ]]; then
  echo "❌ Could not detect MySQL container."
  echo "➡️ Run: docker ps  and ensure mysql container is running."
  exit 1
fi
echo "ℹ️  Detected MySQL container: $MYSQL_CONTAINER"

# Read DB info from /opt/pasarguard/.env (NO PROMPTS for MySQL passwords)
MYSQL_ROOT_PASSWORD="$(get_env_val "MYSQL_ROOT_PASSWORD" "$PASARGUARD_ENV" || true)"
DB_NAME="$(get_env_val "DB_NAME" "$PASARGUARD_ENV" || true)"
[[ -n "$DB_NAME" ]] || DB_NAME="$(get_env_val "MYSQL_DATABASE" "$PASARGUARD_ENV" || true)"
[[ -n "$DB_NAME" ]] || DB_NAME="pasarguard"

MYSQL_USER="$(get_env_val "MYSQL_USER" "$PASARGUARD_ENV" || true)"
[[ -n "$MYSQL_USER" ]] || MYSQL_USER="$(get_env_val "DB_USER" "$PASARGUARD_ENV" || true)"
[[ -n "$MYSQL_USER" ]] || MYSQL_USER="pasarguard"

MYSQL_PASSWORD="$(get_env_val "MYSQL_PASSWORD" "$PASARGUARD_ENV" || true)"
[[ -n "$MYSQL_PASSWORD" ]] || MYSQL_PASSWORD="$(get_env_val "DB_PASSWORD" "$PASARGUARD_ENV" || true)"
# if still empty, we keep empty and user can edit later

if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
  echo "❌ MYSQL_ROOT_PASSWORD not found in $PASARGUARD_ENV"
  echo "➡️ Please ensure /opt/pasarguard/.env contains MYSQL_ROOT_PASSWORD=..."
  exit 1
fi

TIMEZONE="$(prompt "Timezone" "Asia/Tehran")"

# Telegram prompts (SHOW token back to user)
BOT_TOKEN_RAW="$(prompt "Telegram Bot Token" "")"
CHAT_ID="$(prompt "Telegram Chat ID" "")"

# sanitize token: take first token before whitespace
BOT_TOKEN="$(echo "$BOT_TOKEN_RAW" | tr -d '\r' | awk '{print $1}')"

if [[ -z "$BOT_TOKEN" ]]; then
  echo "❌ Telegram Bot Token is empty."
  exit 1
fi
if [[ -z "$CHAT_ID" ]]; then
  echo "❌ Telegram Chat ID is empty."
  exit 1
fi

echo "✅ Telegram Bot Token entered: $BOT_TOKEN"
echo "✅ Telegram Chat ID: $CHAT_ID"

echo "ℹ️  Installing into: $APP_DIR"
mkdir -p "$APP_DIR"
chmod 755 "$APP_DIR"

# requirements
cat > "$APP_DIR/requirements.txt" <<'REQ'
pymysql==1.1.2
requests==2.32.5
jdatetime==5.2.0
python-dotenv==1.2.1
REQ

# daily_digest.py (compact daily per-admin digest)
cat > "$APP_DIR/daily_digest.py" <<'PY'
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

REPORT_INCLUDE_RESETS = os.getenv("REPORT_INCLUDE_RESETS", "0") == "1"

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

def yesterday_range_tehran():
    now = datetime.now(TZ)
    start_today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    start_yesterday = start_today - timedelta(days=1)
    return start_yesterday, start_today

def fetch_events(start_dt, end_dt):
    conn = pymysql.connect(
        host=MYSQL_HOST, port=MYSQL_PORT,
        user=MYSQL_USER, password=MYSQL_PASSWORD,
        database=MYSQL_DATABASE,
        cursorclass=pymysql.cursors.DictCursor,
        connect_timeout=10,
        autocommit=True
    )
    try:
        with conn.cursor() as cur:
            cur.execute("""
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
                ORDER BY e.admin_id ASC, e.id ASC
            """, (start_dt.replace(tzinfo=None), end_dt.replace(tzinfo=None)))
            return cur.fetchall()
    finally:
        conn.close()

def main():
    if not BOT_TOKEN or not CHAT_ID:
        raise SystemExit("Missing TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID in .env")

    start_dt, end_dt = yesterday_range_tehran()

    # Jalali date like 1404-10-07
    j = jdatetime.date.fromgregorian(date=start_dt.date())
    jalali = f"{j.year:04d}-{j.month:02d}-{j.day:02d}"

    rows = fetch_events(start_dt, end_dt)

    # Only important + low-noise events
    allowed = {"USER_CREATED", "DATA_LIMIT_CHANGED", "UNLIMITED_CREATED", "LIMIT_TO_UNLIMITED"}
    if REPORT_INCLUDE_RESETS:
        allowed.add("USAGE_RESET")

    rows = [r for r in rows if r["event_type"] in allowed]

    if not rows:
        return

    # group by admin
    by_admin = {}
    for r in rows:
        by_admin.setdefault(r.get("admin_id") or 0, []).append(r)

    for admin_id, evs in by_admin.items():
        admin_name = evs[0].get("admin_username") or f"admin_id={admin_id}"

        # per-user aggregate
        # state: username -> {"unlimited": bool, "delta_bytes": int, "unlimited_was_bytes": int|None}
        user_state = {}
        for e in evs:
            u = e.get("username") or f"user_id={e.get('user_id')}"
            st = user_state.setdefault(u, {"unlimited": False, "delta_bytes": 0, "unlimited_was_bytes": None, "resets": 0})

            t = e["event_type"]

            if t == "UNLIMITED_CREATED":
                st["unlimited"] = True
                continue

            if t == "LIMIT_TO_UNLIMITED":
                st["unlimited"] = True
                if e.get("old_data_limit") is not None:
                    st["unlimited_was_bytes"] = int(e["old_data_limit"])
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
                    # if it becomes unlimited, it should come as LIMIT_TO_UNLIMITED trigger, but just in case:
                    if newv is None:
                        st["unlimited"] = True
                        if oldv is not None:
                            st["unlimited_was_bytes"] = int(oldv)
                    continue
                st["delta_bytes"] += int(newv) - int(oldv)
                continue

            if t == "USAGE_RESET":
                st["resets"] += 1
                continue

        # build message
        lines = [f"<b>{jalali}</b>", f"Admin: <b>{admin_name}</b>", ""]
        total_pos_gb = 0.0
        any_line = False

        for u in sorted(user_state.keys()):
            st = user_state[u]

            if st["unlimited"]:
                if st["unlimited_was_bytes"] is not None:
                    was_gb = gb_from_bytes(st["unlimited_was_bytes"])
                    lines.append(f"- {u}: unlimited (was {fmt_gb(was_gb)})")
                else:
                    lines.append(f"- {u}: unlimited")
                any_line = True
                continue

            delta = st["delta_bytes"]
            if delta > 0:
                g = gb_from_bytes(delta)
                total_pos_gb += g
                lines.append(f"- {u}: +{fmt_gb(g)}")
                any_line = True

            # ignore decreases (delta < 0) to reduce noise

            if REPORT_INCLUDE_RESETS and st["resets"] > 0:
                lines.append(f"- {u}: reset x{st['resets']}")
                any_line = True

        if not any_line:
            return

        lines.append("")
        lines.append(f"Total: <b>{fmt_gb(total_pos_gb)}</b>")

        send("\n".join(lines))
        time.sleep(0.5)

if __name__ == "__main__":
    main()
PY

# triggers.sql (PasarGuard-only)
cat > "$APP_DIR/triggers.sql" <<'SQL'
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
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
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
  IF (OLD.data_limit IS NOT NULL AND NEW.data_limit IS NULL) THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, old_data_limit, new_data_limit, old_used, new_used)
    VALUES ('LIMIT_TO_UNLIMITED', NEW.admin_id, NEW.id, NEW.username, OLD.data_limit, NEW.data_limit, OLD.used_traffic, NEW.used_traffic);

  ELSEIF (OLD.data_limit IS NULL AND NEW.data_limit IS NOT NULL) THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, old_data_limit, new_data_limit, old_used, new_used)
    VALUES ('UNLIMITED_TO_LIMIT', NEW.admin_id, NEW.id, NEW.username, OLD.data_limit, NEW.data_limit, OLD.used_traffic, NEW.used_traffic);

  ELSEIF (OLD.data_limit <> NEW.data_limit) THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, old_data_limit, new_data_limit, old_used, new_used)
    VALUES ('DATA_LIMIT_CHANGED', NEW.admin_id, NEW.id, NEW.username, OLD.data_limit, NEW.data_limit, OLD.used_traffic, NEW.used_traffic);
  END IF;

  IF (OLD.used_traffic > NEW.used_traffic) THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, old_used, new_used)
    VALUES ('USAGE_RESET', NEW.admin_id, NEW.id, NEW.username, OLD.used_traffic, NEW.used_traffic);
  END IF;
END $$

DELIMITER ;
SQL

echo "ℹ️  Creating Python venv..."
python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" -q install --upgrade pip >/dev/null
"$APP_DIR/.venv/bin/pip" -q install -r "$APP_DIR/requirements.txt" >/dev/null
echo "✅ Python deps installed."

# Create app .env (no prompt for mysql creds)
cat > "$APP_DIR/.env" <<EOF
TIMEZONE=$TIMEZONE

TELEGRAM_BOT_TOKEN=$BOT_TOKEN
TELEGRAM_CHAT_ID=$CHAT_ID

MYSQL_HOST=127.0.0.1
MYSQL_PORT=3306
MYSQL_USER=$MYSQL_USER
MYSQL_PASSWORD=$MYSQL_PASSWORD
MYSQL_DATABASE=$DB_NAME

REPORT_INCLUDE_RESETS=0
EOF
chmod 600 "$APP_DIR/.env"

echo "ℹ️  Applying triggers inside MySQL container: $MYSQL_CONTAINER (db: $DB_NAME)"
# avoid -p warning by using MYSQL_PWD env inside container
docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$MYSQL_CONTAINER" mysql -uroot "$DB_NAME" < "$APP_DIR/triggers.sql"
echo "✅ Triggers applied."

echo "ℹ️  Installing cron (daily 00:00 Asia/Tehran)..."
CRON_LINE="0 0 * * * TZ=$TIMEZONE $APP_DIR/.venv/bin/python $APP_DIR/daily_digest.py >> $LOG_FILE 2>&1"
TMP_CRON="$(mktemp)"
( crontab -l 2>/dev/null || true ) | sed '/BEGIN pasarguard-admin-report/,/END pasarguard-admin-report/d' > "$TMP_CRON"
{
  echo "# BEGIN pasarguard-admin-report"
  echo "$CRON_LINE"
  echo "# END pasarguard-admin-report"
} >> "$TMP_CRON"
crontab "$TMP_CRON"
rm -f "$TMP_CRON"

touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

echo "✅ Cron installed."
echo "✅ Installed!"
echo "ℹ️  Files: $APP_DIR"
echo "ℹ️  Log:   $LOG_FILE"
echo "ℹ️  Test now (may send only if yesterday had events):"
echo "  $APP_DIR/.venv/bin/python $APP_DIR/daily_digest.py"
echo
echo "ℹ️  If your MySQL is NOT exposed on 127.0.0.1:3306, edit:"
echo "  $APP_DIR/.env"
