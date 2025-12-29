sudo tee /opt/pasarguard-admin-report/install.sh >/dev/null <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="pasarguard-admin-report"
INSTALL_DIR="/opt/pasarguard-admin-report"
LOG_FILE="/var/log/pasarguard-admin-report.log"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "❌ Please run as root: sudo bash install.sh"
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

prompt() {
  local var="$1"
  local text="$2"
  local def="${3:-}"
  local secret="${4:-0}"

  if [[ "$secret" == "1" ]]; then
    read -r -s -p "$text" val
    echo
  else
    if [[ -n "$def" ]]; then
      read -r -p "$text (default: $def): " val
    else
      read -r -p "$text: " val
    fi
  fi
  if [[ -z "${val:-}" ]]; then
    val="$def"
  fi
  printf -v "$var" '%s' "$val"
}

load_pasarguard_env_if_exists() {
  # تلاش برای پیدا کردن MYSQL_ROOT_PASSWORD و ... از فایل پنل
  local pg_env="/opt/pasarguard/.env"
  if [[ -f "$pg_env" ]]; then
    # shellcheck disable=SC1090
    set +u
    source "$pg_env" || true
    set -u
  fi
}

write_env() {
  mkdir -p "$INSTALL_DIR"
  cat > "$INSTALL_DIR/.env" <<EOF
# PasarGuard Admin Report (Daily Digest)
TIMEZONE=${TIMEZONE}

# Telegram
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}

# Docker MySQL (PasarGuard)
DOCKER_MYSQL_CONTAINER=${DOCKER_MYSQL_CONTAINER}
DOCKER_MYSQL_ROOT_PASSWORD=${DOCKER_MYSQL_ROOT_PASSWORD}
MYSQL_DATABASE=${MYSQL_DATABASE}
EOF
  chmod 600 "$INSTALL_DIR/.env"
}

install_packages() {
  echo "📦 Installing packages..."
  apt-get update -y >/dev/null
  apt-get install -y python3 python3-venv python3-pip cron >/dev/null
  if ! have_cmd docker; then
    echo "❌ docker not found. Install Docker first."
    exit 1
  fi
}

setup_venv() {
  echo "🐍 Setting up venv..."
  cd "$INSTALL_DIR"
  python3 -m venv .venv
  . "$INSTALL_DIR/.venv/bin/activate"
  pip install -U pip >/dev/null
  pip install -r "$INSTALL_DIR/requirements.txt" >/dev/null
}

apply_triggers() {
  echo "🧩 Applying triggers.sql inside docker mysql..."
  if ! docker ps --format '{{.Names}}' | grep -qx "$DOCKER_MYSQL_CONTAINER"; then
    echo "❌ MySQL container not found: $DOCKER_MYSQL_CONTAINER"
    echo "➡️ Run: docker ps"
    exit 1
  fi

  # اجرای triggers داخل کانتینر
  docker exec -i "$DOCKER_MYSQL_CONTAINER" \
    mysql -uroot -p"$DOCKER_MYSQL_ROOT_PASSWORD" < "$INSTALL_DIR/triggers.sql" >/dev/null

  echo "✅ Triggers applied."
}

install_cron() {
  echo "⏰ Installing cron (daily 00:00 Asia/Tehran)..."

  local cron_line="0 0 * * * TZ=${TIMEZONE} ${INSTALL_DIR}/.venv/bin/python ${INSTALL_DIR}/daily_digest.py >> ${LOG_FILE} 2>&1"
  local marker_begin="# BEGIN ${APP_NAME}"
  local marker_end="# END ${APP_NAME}"

  # crontab فعلی
  local tmp
  tmp="$(mktemp)"

  crontab -l 2>/dev/null > "$tmp" || true

  # پاک کردن بلاک قبلی اگر وجود داشت
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

  echo "✅ Cron installed."
}

sanity_test() {
  echo "🧪 Quick test (dry run: might send message only if yesterday had events)..."
  set +e
  "$INSTALL_DIR/.venv/bin/python" "$INSTALL_DIR/daily_digest.py" >/dev/null 2>&1
  set -e
  echo "ℹ️ Log: $LOG_FILE"
}

main() {
  need_root

  echo "======================================"
  echo "✅ ${APP_NAME} Installer"
  echo "======================================"

  install_packages

  load_pasarguard_env_if_exists

  # Defaults
  : "${MYSQL_ROOT_PASSWORD:=}"
  : "${MYSQL_DATABASE:=pasarguard}"

  prompt TIMEZONE "Timezone" "Asia/Tehran"
  prompt TELEGRAM_BOT_TOKEN "Telegram Bot Token"
  prompt TELEGRAM_CHAT_ID "Telegram Chat ID"
  prompt DOCKER_MYSQL_CONTAINER "MySQL docker container name" "pasarguard-mysql-1"

  # اگر از /opt/pasarguard/.env خوندیم، پیش‌فرض می‌دیم
  if [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
    prompt DOCKER_MYSQL_ROOT_PASSWORD "MySQL ROOT password" "${MYSQL_ROOT_PASSWORD}" 1
  else
    prompt DOCKER_MYSQL_ROOT_PASSWORD "MySQL ROOT password" "" 1
  fi

  prompt MYSQL_DATABASE "MySQL Database name" "pasarguard"

  # کپی فایل‌ها به /opt
  echo "📁 Copying files to ${INSTALL_DIR} ..."
  mkdir -p "$INSTALL_DIR"

  # اگر install.sh از داخل یک clone اجرا شده باشد، فایل‌های همانجا را کپی می‌کنیم
  SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cp -a "$SRC_DIR/." "$INSTALL_DIR/"

  write_env
  setup_venv
  apply_triggers
  install_cron
  sanity_test

  echo
  echo "✅ Installed!"
  echo "➡️ Next: create/change some users, then wait until 00:00 Tehran for the daily report."
  echo "➡️ View logs: tail -n 200 ${LOG_FILE}"
}

main "$@"
BASH
