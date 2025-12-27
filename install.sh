#!/usr/bin/env bash
set -e

APP_NAME="pasarguard-admin-report"
APP_DIR="/opt/pasarguard-admin-report"
PY_SCRIPT="pasarguard_admin_report.py"
ENV_FILE=".env"
VENV_DIR=".venv"
CRON_TAG="# pasarguard-admin-report"

echo "======================================"
echo "✅ $APP_NAME Installer"
echo "======================================"
echo ""

# -----------------------
# Check root
# -----------------------
if [[ $EUID -ne 0 ]]; then
  echo "❌ Please run as root:"
  echo "   sudo bash install.sh"
  exit 1
fi

# -----------------------
# Install dependencies
# -----------------------
echo "📦 Installing system packages..."
apt update -y
apt install -y python3 python3-venv python3-pip git cron nano mysql-client

# Ensure cron is running
systemctl enable cron >/dev/null 2>&1 || true
systemctl restart cron >/dev/null 2>&1 || true

# -----------------------
# Copy files to /opt
# -----------------------
echo "📁 Installing script into: $APP_DIR"
mkdir -p "$APP_DIR"
cp -r ./* "$APP_DIR"
cd "$APP_DIR"

# -----------------------
# Config Wizard
# -----------------------
echo ""
echo "⚙️ Configuration Wizard"
echo "--------------------------------------"

read -p "MySQL Host (default: 127.0.0.1): " MYSQL_HOST
MYSQL_HOST=${MYSQL_HOST:-127.0.0.1}

read -p "MySQL Port (default: 3306): " MYSQL_PORT
MYSQL_PORT=${MYSQL_PORT:-3306}

read -p "MySQL Username (default: root): " MYSQL_USER
MYSQL_USER=${MYSQL_USER:-root}

read -s -p "MySQL Password: " MYSQL_PASS
echo ""

read -p "MySQL Database (default: pasarguard): " MYSQL_DB
MYSQL_DB=${MYSQL_DB:-pasarguard}

echo ""
read -p "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
read -p "Telegram Chat ID: " TELEGRAM_CHAT_ID

read -p "Timezone (default: Asia/Tehran): " TZ
TZ=${TZ:-Asia/Tehran}

# -----------------------
# Write .env
# -----------------------
echo ""
echo "✅ Writing .env ..."
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

# -----------------------
# Create venv + install requirements
# -----------------------
echo ""
echo "🐍 Creating python virtualenv..."
python3 -m venv "$VENV_DIR"

echo "📦 Installing python dependencies..."
source "$VENV_DIR/bin/activate"
pip install --upgrade pip >/dev/null
pip install -r requirements.txt
deactivate

# -----------------------
# Test MySQL connection
# -----------------------
echo ""
echo "🔍 Testing MySQL connection..."

if mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB" -e "SELECT 1;" >/dev/null 2>&1; then
  echo "✅ MySQL connection OK!"
else
  echo "❌ Cannot connect to MySQL."
  echo "➡️ Please check host/port/user/password/database."
  echo "➡️ Installer will stop."
  exit 1
fi

# -----------------------
# Install Triggers (optional)
# -----------------------
echo ""
read -p "📌 Install triggers.sql (recommended)? (y/n): " INSTALL_TRIGGERS
INSTALL_TRIGGERS=${INSTALL_TRIGGERS,,}

if [[ "$INSTALL_TRIGGERS" == "y" ]]; then
  if [[ -f "triggers.sql" ]]; then
    echo "⚡ Installing triggers..."
    mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB" < triggers.sql
    echo "✅ Triggers installed!"
  else
    echo "⚠️ triggers.sql not found. Skipping."
  fi
else
  echo "⏭ Skipping triggers installation."
fi

# -----------------------
# Setup cron jobs (no duplicates)
# -----------------------
echo ""
echo "⏰ Setting up cron jobs..."

CRON_DAILY="5 0 * * * TZ=$TZ $APP_DIR/$VENV_DIR/bin/python $APP_DIR/$PY_SCRIPT >> /var/log/pasarguard_admin_report.log 2>&1"
CRON_WEEKLY="10 0 * * 6 TZ=$TZ $APP_DIR/$VENV_DIR/bin/python $APP_DIR/$PY_SCRIPT weekly >> /var/log/pasarguard_weekly.log 2>&1"
CRON_MONTHLY="15 0 1 * * TZ=$TZ $APP_DIR/$VENV_DIR/bin/python $APP_DIR/$PY_SCRIPT monthly >> /var/log/pasarguard_monthly.log 2>&1"

# Remove old entries
crontab -l 2>/dev/null | grep -v "$CRON_TAG" > /tmp/cron_tmp || true

# Add new entries
{
  cat /tmp/cron_tmp
  echo "$CRON_TAG"
  echo "$CRON_DAILY $CRON_TAG"
  echo "$CRON_WEEKLY $CRON_TAG"
  echo "$CRON_MONTHLY $CRON_TAG"
} | crontab -

rm -f /tmp/cron_tmp

echo "✅ Cron jobs installed!"

# -----------------------
# Done
# -----------------------
echo ""
echo "✅ Installation finished!"
echo ""
echo "📌 Logs:"
echo "  Daily:   /var/log/pasarguard_admin_report.log"
echo "  Weekly:  /var/log/pasarguard_weekly.log"
echo "  Monthly: /var/log/pasarguard_monthly.log"
echo ""

# -----------------------
# Test run (optional)
# -----------------------
read -p "📌 Test run now? Run daily report test now? (y/n): " RUN_TEST
RUN_TEST=${RUN_TEST,,}

if [[ "$RUN_TEST" == "y" ]]; then
  echo "🚀 Running daily report test..."
  $APP_DIR/$VENV_DIR/bin/python $APP_DIR/$PY_SCRIPT
  echo "✅ Test finished."
else
  echo "⏭ Skipping test."
fi
