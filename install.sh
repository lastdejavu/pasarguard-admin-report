#!/usr/bin/env bash
set -e

APP_NAME="pasarguard-admin-report"
APP_DIR="/opt/pasarguard-admin-report"
PY_SCRIPT="pasarguard_admin_report.py"
ENV_FILE=".env"
VENV_DIR=".venv"

echo "======================================"
echo "✅ $APP_NAME Installer"
echo "======================================"
echo ""

# -----------------------------
#  Check root
# -----------------------------
if [[ $EUID -ne 0 ]]; then
   echo "❌ Please run as root: sudo bash install.sh"
   exit 1
fi

# -----------------------------
#  Install packages
# -----------------------------
echo "📦 Installing system packages..."
apt update -y
apt install -y python3 python3-venv python3-pip cron git nano

# -----------------------------
#  Clone / Copy project
# -----------------------------
echo "📁 Installing script into: $APP_DIR"

mkdir -p "$APP_DIR"
cp -r ./* "$APP_DIR"
cd "$APP_DIR"

# -----------------------------
#  Ask user config
# -----------------------------
echo ""
echo "⚙️ Configuration Wizard"
echo "--------------------------------------"

read -p "MySQL Host (default: 127.0.0.1): " MYSQL_HOST
MYSQL_HOST=${MYSQL_HOST:-127.0.0.1}

read -p "MySQL Port (default: 3306): " MYSQL_PORT
MYSQL_PORT=${MYSQL_PORT:-3306}

read -p "MySQL Username (default: root): " MYSQL_USER
MYSQL_USER=${MYSQL_USER:-root}

read -sp "MySQL Password: " MYSQL_PASS
echo ""

read -p "MySQL Database (default: pasarguard): " MYSQL_DB
MYSQL_DB=${MYSQL_DB:-pasarguard}

echo ""
read -p "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
read -p "Telegram Chat ID: " TELEGRAM_CHAT_ID

echo ""
read -p "Timezone (default: Asia/Tehran): " TZ
TZ=${TZ:-Asia/Tehran}

echo ""
echo "✅ Writing $ENV_FILE ..."

cat > "$ENV_FILE" <<EOF
MYSQL_HOST=$MYSQL_HOST
MYSQL_PORT=$MYSQL_PORT
MYSQL_USER=$MYSQL_USER
MYSQL_PASS=$MYSQL_PASS
MYSQL_DB=$MYSQL_DB

TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID

TZ=$TZ
EOF

chmod 600 "$ENV_FILE"

# -----------------------------
#  Create venv & install deps
# -----------------------------
echo ""
echo "🐍 Creating python virtualenv..."
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

echo "📦 Installing python dependencies..."
pip install --upgrade pip
pip install -r requirements.txt

deactivate

# -----------------------------
#  Cron jobs
# -----------------------------
echo ""
echo "⏰ Setting up cron jobs..."

CRON_DAILY="5 0 * * * TZ=$TZ $APP_DIR/$VENV_DIR/bin/python $APP_DIR/$PY_SCRIPT >> /var/log/pasarguard_admin_report.log 2>&1"
CRON_WEEKLY="10 0 * * 6 TZ=$TZ $APP_DIR/$VENV_DIR/bin/python $APP_DIR/$PY_SCRIPT weekly >> /var/log/pasarguard_weekly.log 2>&1"
CRON_MONTHLY="15 0 1 * * TZ=$TZ $APP_DIR/$VENV_DIR/bin/python $APP_DIR/$PY_SCRIPT monthly >> /var/log/pasarguard_monthly.log 2>&1"

(crontab -l 2>/dev/null | grep -v "$APP_DIR/$PY_SCRIPT" || true; echo "$CRON_DAILY"; echo "$CRON_WEEKLY"; echo "$CRON_MONTHLY") | crontab -

echo "✅ Cron jobs installed!"
echo ""

# -----------------------------
#  Final test
# -----------------------------
echo "✅ Installation finished!"
echo ""
echo "📌 Test run now?"
read -p "Run daily test now? (y/n): " RUN_TEST

if [[ "$RUN_TEST" == "y" ]]; then
    echo "🚀 Running daily report test..."
    source "$VENV_DIR/bin/activate"
    python "$PY_SCRIPT"
    deactivate
    echo "✅ Test finished. Check Telegram."
fi

echo ""
echo "======================================"
echo "✅ Done! Installed at: $APP_DIR"
echo "Logs:"
echo " - /var/log/pasarguard_admin_report.log"
echo " - /var/log/pasarguard_weekly.log"
echo " - /var/log/pasarguard_monthly.log"
echo "======================================"
