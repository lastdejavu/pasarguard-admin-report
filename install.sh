#!/usr/bin/env bash
set -euo pipefail

echo "======================================"
echo "✅ pasarguard-admin-report one-line installer"
echo "======================================"

if [[ "${EUID:-0}" -ne 0 ]]; then
  echo "❌ Please run as root (use sudo)."
  exit 1
fi

APP_DIR="/opt/pasarguard-admin-report"
PASARGUARD_ENV_DEFAULT="/opt/pasarguard/.env"

# -------- helpers --------
need_cmd() { command -v "$1" >/dev/null 2>&1; }

read_env_val() {
  # read_env_val KEY FILE
  local key="$1" file="$2"
  grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

trim() {
  # trim spaces/newlines
  echo -n "$1" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//'
}

# -------- packages --------
echo "ℹ️  Installing packages (python3, venv, cron, curl)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y python3 python3-venv python3-pip cron curl >/dev/null
echo "✅ Packages installed."

# -------- docker presence --------
if ! need_cmd docker; then
  echo "❌ Docker not found. PasarGuard must be installed via Docker."
  exit 1
fi

# -------- find pasarguard env --------
PASARGUARD_ENV="${PASARGUARD_ENV:-$PASARGUARD_ENV_DEFAULT}"
if [[ ! -f "$PASARGUARD_ENV" ]]; then
  echo "❌ PasarGuard env not found at: $PASARGUARD_ENV"
  echo "   Set PASARGUARD_ENV=/path/to/.env and re-run."
  exit 1
fi
echo "ℹ️  Found PasarGuard env: $PASARGUARD_ENV"

MYSQL_ROOT_PASSWORD="$(trim "$(read_env_val MYSQL_ROOT_PASSWORD "$PASARGUARD_ENV")")"
DB_NAME="$(trim "$(read_env_val DB_NAME "$PASARGUARD_ENV")")"
[[ -z "$DB_NAME" ]] && DB_NAME="pasarguard"

if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
  echo "❌ MYSQL_ROOT_PASSWORD not found in $PASARGUARD_ENV"
  exit 1
fi

# -------- detect mysql container --------
MYSQL_CONTAINER="${MYSQL_CONTAINER:-}"
if [[ -z "$MYSQL_CONTAINER" ]]; then
  # prefer pasarguard-mysql-1
  if docker ps --format '{{.Names}}' | grep -qx 'pasarguard-mysql-1'; then
    MYSQL_CONTAINER="pasarguard-mysql-1"
  else
    # fallback: first container whose image/name looks like mysql
    MYSQL_CONTAINER="$(docker ps --format '{{.Names}} {{.Image}}' | awk 'tolower($0) ~ /mysql/ {print $1; exit}')"
  fi
fi

if [[ -z "$MYSQL_CONTAINER" ]]; then
  echo "❌ Could not detect MySQL container. Set MYSQL_CONTAINER=... and re-run."
  docker ps --format "table {{.Names}}\t{{.Image}}"
  exit 1
fi
echo "ℹ️  Detected MySQL container: $MYSQL_CONTAINER"
echo "ℹ️  DB name: $DB_NAME"

# -------- telegram config (non-interactive supported) --------
# You can pass env vars:
#   TELEGRAM_BOT_TOKEN="xxx" TELEGRAM_CHAT_ID="yyy" curl ... | sudo -E bash
TIMEZONE="${TIMEZONE:-Asia/Tehran}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# If existing .env exists, reuse values unless explicitly provided
if [[ -f "$APP_DIR/.env" ]]; then
  prev_bot="$(trim "$(read_env_val TELEGRAM_BOT_TOKEN "$APP_DIR/.env")")"
  prev_chat="$(trim "$(read_env_val TELEGRAM_CHAT_ID "$APP_DIR/.env")")"
  prev_tz="$(trim "$(read_env_val TIMEZONE "$APP_DIR/.env")")"
  [[ -z "$BOT_TOKEN" ]] && BOT_TOKEN="$prev_bot"
  [[ -z "$CHAT_ID" ]] && CHAT_ID="$prev_chat"
  [[ -z "${TIMEZONE:-}" ]] && TIMEZONE="${prev_tz:-Asia/Tehran}"
fi

if [[ -z "$BOT_TOKEN" ]]; then
  echo -n "Telegram Bot Token: "
  read -r BOT_TOKEN
  BOT_TOKEN="$(trim "$BOT_TOKEN")"
fi

if [[ -z "$CHAT_ID" ]]; then
  echo -n "Telegram Chat ID: "
  read -r CHAT_ID
  CHAT_ID="$(trim "$CHAT_ID")"
fi

if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
  echo "❌ Telegram Bot Token / Chat ID is required."
  exit 1
fi

# -------- create dir --------
mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR"

# -------- write requirements --------
cat >"$APP_DIR/requirements.txt" <<'REQ'
requests==2.32.3
python-dotenv==1.0.1
jdatetime==5.0.0
REQ

# -------- write triggers.sql (reported_at) --------
cat >"$APP_DIR/triggers.sql" <<'SQL'
-- NOTE:
-- Installer runs this file with the correct database selected (DB_NAME).
-- So we do NOT hardcode "USE pasarguard;" here.

-- Create table if missing (new installs)
CREATE TABLE IF NOT EXISTS admin_report_events (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

  event_type VARCHAR(64) NOT NULL,

  admin_id BIGINT NULL,
  user_id  BIGINT NULL,
  username VARCHAR(255) NULL,

  old_data_limit BIGINT NULL,
  new_data_limit BIGINT NULL,

  old_used BIGINT NULL,
  new_used BIGINT NULL,

  reported_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

  INDEX idx_reported_at (reported_at),
  INDEX idx_admin_time (admin_id, reported_at),
  INDEX idx_user_time (user_id, reported_at)
);

-- Migration for older installs: if table exists but reported_at does not, add it.
SET @has_col := (
  SELECT COUNT(*)
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME = 'admin_report_events'
    AND COLUMN_NAME = 'reported_at'
);

SET @sql := IF(
  @has_col = 0,
  'ALTER TABLE admin_report_events ADD COLUMN reported_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP',
  'SELECT 1'
);

PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- If older installs used created_at, copy to reported_at when reported_at is null-ish (rare).
-- Safe best-effort:
SET @has_created_at := (
  SELECT COUNT(*)
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME = 'admin_report_events'
    AND COLUMN_NAME = 'created_at'
);

SET @sql2 := IF(
  @has_created_at > 0,
  'UPDATE admin_report_events SET reported_at = created_at WHERE reported_at IS NULL',
  'SELECT 1'
);

PREPARE stmt2 FROM @sql2;
EXECUTE stmt2;
DEALLOCATE PREPARE stmt2;

DELIMITER $$

DROP TRIGGER IF EXISTS trg_report_user_create $$
CREATE TRIGGER trg_report_user_create
AFTER INSERT ON users
FOR EACH ROW
BEGIN
  IF NEW.data_limit IS NULL THEN
    INSERT INTO admin_report_events(
      event_type, admin_id, user_id, username,
      new_data_limit, new_used
    )
    VALUES (
      'UNLIMITED_CREATED', NEW.admin_id, NEW.id, NEW.username,
      NULL, NEW.used_traffic
    );
  ELSE
    INSERT INTO admin_report_events(
      event_type, admin_id, user_id, username,
      new_data_limit, new_used
    )
    VALUES (
      'USER_CREATED', NEW.admin_id, NEW.id, NEW.username,
      NEW.data_limit, NEW.used_traffic
    );
  END IF;
END $$

DROP TRIGGER IF EXISTS trg_report_user_update $$
CREATE TRIGGER trg_report_user_update
AFTER UPDATE ON users
FOR EACH ROW
BEGIN
  -- limited -> unlimited
  IF (OLD.data_limit IS NOT NULL AND NEW.data_limit IS NULL) THEN
    INSERT INTO admin_report_events(
      event_type, admin_id, user_id, username,
      old_data_limit, new_data_limit, old_used, new_used
    )
    VALUES (
      'LIMIT_TO_UNLIMITED', NEW.admin_id, NEW.id, NEW.username,
      OLD.data_limit, NULL, OLD.used_traffic, NEW.used_traffic
    );

  -- unlimited -> limited
  ELSEIF (OLD.data_limit IS NULL AND NEW.data_limit IS NOT NULL) THEN
    INSERT INTO admin_report_events(
      event_type, admin_id, user_id, username,
      old_data_limit, new_data_limit, old_used, new_used
    )
    VALUES (
      'UNLIMITED_TO_LIMIT', NEW.admin_id, NEW.id, NEW.username,
      NULL, NEW.data_limit, OLD.used_traffic, NEW.used_traffic
    );

  -- limited -> limited limit change
  ELSEIF (OLD.data_limit <> NEW.data_limit) THEN
    INSERT INTO admin_report_events(
      event_type, admin_id, user_id, username,
      old_data_limit, new_data_limit, old_used, new_used
    )
    VALUES (
      'DATA_LIMIT_CHANGED', NEW.admin_id, NEW.id, NEW.username,
      OLD.data_limit, NEW.data_limit, OLD.used_traffic, NEW.used_traffic
    );
  END IF;

  -- usage reset (used decreases)
  IF (OLD.used_traffic > NEW.used_traffic) THEN
    -- IMPORTANT:
    -- store current limit in new_data_limit so digest can charge FULL LIMIT on reset (your policy)
    INSERT INTO admin_report_events(
      event_type, admin_id, user_id, username,
      new_data_limit, old_used, new_used
    )
    VALUES (
      'USAGE_RESET', NEW.admin_id, NEW.id, NEW.username,
      NEW.data_limit, OLD.used_traffic, NEW.used_traffic
    );
  END IF;
END $$

DELIMITER ;
SQL

# -------- write daily_digest.py (uses docker exec, no host mysql needed) --------
cat >"$APP_DIR/daily_digest.py" <<'PY'
import os
import time
import subprocess
import requests
import jdatetime
from dotenv import load_dotenv
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

APP_ENV = "/opt/pasarguard-admin-report/.env"
PASARGUARD_ENV = os.getenv("PASARGUARD_ENV", "/opt/pasarguard/.env")

load_dotenv(APP_ENV)

TZ = ZoneInfo(os.getenv("TIMEZONE", "Asia/Tehran"))

BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "").strip()

MYSQL_CONTAINER = os.getenv("MYSQL_CONTAINER", "pasarguard-mysql-1").strip()

SHOW_LIMIT_AFTER_UNLIMITED = os.getenv("SHOW_LIMIT_AFTER_UNLIMITED", "1") == "1"
CHARGE_FULL_LIMIT_ON_RESET = os.getenv("CHARGE_FULL_LIMIT_ON_RESET", "1") == "1"

def _read_env_val(path: str, key: str) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip()
    except FileNotFoundError:
        return ""
    return ""

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

def tehran_range(mode: str):
    now = datetime.now(TZ)
    start_today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    if mode == "today":
        return start_today, now
    start_yesterday = start_today - timedelta(days=1)
    return start_yesterday, start_today

def _mysql_rows(db: str, sql: str):
    """
    Run SQL inside the MySQL container using root password from PASARGUARD_ENV.
    Returns rows as list[list[str]] from tab-separated output.
    """
    root_pwd = _read_env_val(PASARGUARD_ENV, "MYSQL_ROOT_PASSWORD")
    if not root_pwd:
        raise RuntimeError(f"MYSQL_ROOT_PASSWORD not found in {PASARGUARD_ENV}")

    cmd = [
        "docker", "exec", "-i",
        "-e", f"MYSQL_PWD={root_pwd}",
        MYSQL_CONTAINER,
        "mysql",
        "-uroot",
        "-N", "-B", "--raw",
        db,
        "-e", sql
    ]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip() or "mysql exec failed")

    out = p.stdout.strip("\n")
    if not out:
        return []

    rows = []
    for line in out.splitlines():
        rows.append(line.split("\t"))
    return rows

def _to_int(x):
    if x is None:
        return None
    if x == r"\N" or x == "":
        return None
    try:
        return int(x)
    except Exception:
        return None

def main():
    import sys
    mode = "yesterday"
    if len(sys.argv) >= 2 and sys.argv[1].strip().lower() == "today":
        mode = "today"

    if not BOT_TOKEN or not CHAT_ID:
        raise SystemExit("Missing TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID in /opt/pasarguard-admin-report/.env")

    db_name = _read_env_val(PASARGUARD_ENV, "DB_NAME") or "pasarguard"

    start_dt, end_dt = tehran_range(mode)

    # convert to UTC for querying TIMESTAMP reliably
    start_utc = start_dt.astimezone(timezone.utc).replace(tzinfo=None)
    end_utc = end_dt.astimezone(timezone.utc).replace(tzinfo=None)

    # Jalali date for the report day
    j = jdatetime.date.fromgregorian(date=start_dt.date())
    jalali = f"{j.year:04d}-{j.month:02d}-{j.day:02d}"

    sql = f"""
SET time_zone = '+00:00';
SELECT
  e.event_type,
  e.admin_id,
  COALESCE(a.username,'') AS admin_username,
  COALESCE(e.username,'') AS username,
  e.old_data_limit,
  e.new_data_limit,
  e.old_used,
  e.new_used,
  e.reported_at
FROM admin_report_events e
LEFT JOIN admins a ON a.id = e.admin_id
WHERE e.reported_at >= '{start_utc:%Y-%m-%d %H:%M:%S}'
  AND e.reported_at <  '{end_utc:%Y-%m-%d %H:%M:%S}'
ORDER BY e.admin_id ASC, e.id ASC;
""".strip()

    rows = _mysql_rows(db_name, sql)

    allowed = {
        "USER_CREATED",
        "DATA_LIMIT_CHANGED",
        "UNLIMITED_CREATED",
        "LIMIT_TO_UNLIMITED",
        "UNLIMITED_TO_LIMIT",
        "USAGE_RESET",
    }

    events = []
    for r in rows:
        # columns:
        # 0 event_type, 1 admin_id, 2 admin_username, 3 username,
        # 4 old_data_limit, 5 new_data_limit, 6 old_used, 7 new_used, 8 reported_at
        event_type = r[0]
        if event_type not in allowed:
            continue
        events.append({
            "event_type": event_type,
            "admin_id": _to_int(r[1]) or 0,
            "admin_username": r[2] or "",
            "username": r[3] or "",
            "old_data_limit": _to_int(r[4]),
            "new_data_limit": _to_int(r[5]),
            "old_used": _to_int(r[6]),
            "new_used": _to_int(r[7]),
        })

    if not events:
        return

    by_admin = {}
    for e in events:
        by_admin.setdefault(e["admin_id"], []).append(e)

    for admin_id, evs in by_admin.items():
        admin_name = evs[0]["admin_username"] or f"admin_id={admin_id}"

        # username -> state
        user_state = {}
        for e in evs:
            u = e["username"] or "unknown"
            st = user_state.setdefault(u, {"unlimited": False, "was_limit_bytes": None, "charge_bytes": 0})

            t = e["event_type"]

            if t == "UNLIMITED_CREATED":
                st["unlimited"] = True
                st["was_limit_bytes"] = None
                continue

            if t == "LIMIT_TO_UNLIMITED":
                st["unlimited"] = True
                if e["old_data_limit"] is not None:
                    st["was_limit_bytes"] = int(e["old_data_limit"])
                continue

            if t == "UNLIMITED_TO_LIMIT":
                st["unlimited"] = False
                continue

            if t == "USER_CREATED":
                if e["new_data_limit"] is None:
                    st["unlimited"] = True
                else:
                    st["charge_bytes"] += int(e["new_data_limit"])
                continue

            if t == "DATA_LIMIT_CHANGED":
                oldv = e["old_data_limit"]
                newv = e["new_data_limit"]
                if oldv is None or newv is None:
                    if newv is None:
                        st["unlimited"] = True
                        if oldv is not None:
                            st["was_limit_bytes"] = int(oldv)
                    continue
                diff = int(newv) - int(oldv)
                if diff > 0:
                    st["charge_bytes"] += diff
                continue

            if t == "USAGE_RESET":
                if CHARGE_FULL_LIMIT_ON_RESET:
                    limit_now = e["new_data_limit"]
                    if limit_now is None:
                        # reset on unlimited => no GB charge
                        st["unlimited"] = True
                    else:
                        # charge FULL limit
                        st["charge_bytes"] += int(limit_now)
                else:
                    old_used = e["old_used"] or 0
                    if old_used > 0:
                        st["charge_bytes"] += int(old_used)
                continue

        lines = [f"<b>{jalali}</b>", f"Admin: <b>{admin_name}</b>", ""]
        total_gb = 0.0
        any_line = False

        for u in sorted(user_state.keys()):
            st = user_state[u]

            if st["unlimited"]:
                if SHOW_LIMIT_AFTER_UNLIMITED and st["was_limit_bytes"]:
                    lines.append(f"- {u}: unlimited (was {fmt_gb(gb_from_bytes(st['was_limit_bytes']))})")
                else:
                    lines.append(f"- {u}: unlimited")
                any_line = True
                continue

            charge = st["charge_bytes"]
            if charge <= 0:
                continue

            g = gb_from_bytes(charge)
            total_gb += g
            lines.append(f"- {u}: +{fmt_gb(g)}")
            any_line = True

        if not any_line:
            continue

        lines.append("")
        lines.append(f"Total: <b>{fmt_gb(total_gb)}</b>")

        send("\n".join(lines))
        time.sleep(0.5)

if __name__ == "__main__":
    main()
PY

# -------- write app .env (clean, no duplication) --------
cat >"$APP_DIR/.env" <<EOF
TIMEZONE=${TIMEZONE}
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
TELEGRAM_CHAT_ID=${CHAT_ID}

# Optional:
SHOW_LIMIT_AFTER_UNLIMITED=1
CHARGE_FULL_LIMIT_ON_RESET=1

# Optional override:
# MYSQL_CONTAINER=${MYSQL_CONTAINER}
# PASARGUARD_ENV=${PASARGUARD_ENV_DEFAULT}
EOF
chmod 600 "$APP_DIR/.env"

# -------- validate bot token --------
echo "ℹ️  Validating Telegram bot token..."
if ! curl -fsS "https://api.telegram.org/bot${BOT_TOKEN}/getMe" >/dev/null; then
  echo "❌ Telegram token invalid (getMe failed)."
  echo "   Fix token in $APP_DIR/.env then re-run daily_digest."
  exit 1
fi
echo "✅ Telegram token OK."
echo "ℹ️  Telegram Bot Token (for confirmation): ${BOT_TOKEN}"

# -------- create venv --------
echo "ℹ️  Creating Python venv..."
python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install -U pip >/dev/null
"$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt" >/dev/null
echo "✅ Python deps installed."

# -------- apply triggers inside mysql container --------
echo "ℹ️  Applying triggers inside MySQL container: $MYSQL_CONTAINER (db: $DB_NAME)"
docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$MYSQL_CONTAINER" \
  mysql -uroot "$DB_NAME" < "$APP_DIR/triggers.sql"
echo "✅ Triggers applied."

# -------- install cron (root) --------
echo "ℹ️  Installing cron (daily 00:00 ${TIMEZONE})..."
CRON_LINE="0 0 * * * TZ=${TIMEZONE} ${APP_DIR}/.venv/bin/python ${APP_DIR}/daily_digest.py >> /var/log/pasarguard-admin-report.log 2>&1"
TMP_CRON="$(mktemp)"

# keep existing root cron, remove old block, append new block
( crontab -l 2>/dev/null || true ) | sed '/BEGIN pasarguard-admin-report/,/END pasarguard-admin-report/d' > "$TMP_CRON"
{
  echo "# BEGIN pasarguard-admin-report"
  echo "$CRON_LINE"
  echo "# END pasarguard-admin-report"
} >> "$TMP_CRON"
crontab "$TMP_CRON"
rm -f "$TMP_CRON"
echo "✅ Cron installed."

# -------- quick test message (optional) --------
echo "ℹ️  Sending test message to Telegram..."
curl -fsS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d "chat_id=${CHAT_ID}" \
  -d "text=pasarguard-admin-report نصب شد ✅" >/dev/null || true
echo "✅ Installed!"
echo "ℹ️  Files: $APP_DIR"
echo "ℹ️  Log:   /var/log/pasarguard-admin-report.log"
echo
echo "ℹ️  Test now (today mode):"
echo "  ${APP_DIR}/.venv/bin/python ${APP_DIR}/daily_digest.py today"
echo
echo "ℹ️  Default cron sends yesterday digest at 00:00 ${TIMEZONE}."
echo "======================================"
