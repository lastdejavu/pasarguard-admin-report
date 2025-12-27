#!/usr/bin/env bash
set -e

APP_NAME="pasarguard-admin-report"
INSTALL_DIR="/opt/$APP_NAME"
REPO_DIR="$(pwd)"

echo "======================================"
echo "✅ $APP_NAME Installer"
echo "======================================"
echo ""

# ---------------------------
# Install system packages
# ---------------------------
echo "📦 Installing system packages..."
apt update -y
apt install -y python3 python3-pip python3-venv cron git nano mariadb-client

echo ""
echo "📁 Installing script into: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -r "$REPO_DIR/"* "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ---------------------------
# Configuration Wizard
# ---------------------------
echo ""
echo "⚙️ Configuration Wizard"
echo "--------------------------------------"

read -rp "MySQL Host (default: 127.0.0.1): " MYSQL_HOST
MYSQL_HOST=${MYSQL_HOST:-127.0.0.1}

read -rp "MySQL Port (default: 3306): " MYSQL_PORT
MYSQL_PORT=${MYSQL_PORT:-3306}

read -rp "MySQL Username (default: root): " MYSQL_USER
MYSQL_USER=${MYSQL_USER:-root}

read -rsp "MySQL Password: " MYSQL_PASS
echo ""

read -rp "MySQL Database (default: pasarguard): " MYSQL_DB
MYSQL_DB=${MYSQL_DB:-pasarguard}

echo ""
read -rp "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
read -rp "Telegram Chat ID: " TELEGRAM_CHAT_ID

read -rp "Timezone (default: Asia/Tehran): " TZ
TZ=${TZ:-Asia/Tehran}

# ---------------------------
# Write .env
# ---------------------------
echo ""
echo "✅ Writing .env ..."
cat > .env <<EOF
MYSQL_HOST=$MYSQL_HOST
MYSQL_PORT=$MYSQL_PORT
MYSQL_USER=$MYSQL_USER
MYSQL_PASS=$MYSQL_PASS
MYSQL_DB=$MYSQL_DB

TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID

TZ=$TZ
EOF

# ---------------------------
# Create venv & install deps
# ---------------------------
echo ""
echo "🐍 Creating python virtualenv..."
python3 -m venv .venv
source .venv/bin/activate

echo "📦 Installing python dependencies..."
pip install --upgrade pip
pip install -r requirements.txt

# ---------------------------
# Install triggers
# ---------------------------
echo ""
read -rp "Install database triggers? (recommended) (y/n): " INSTALL_TRIGGERS
if [[ "$INSTALL_TRIGGERS" == "y" || "$INSTALL_TRIGGERS" == "Y" ]]; then
  echo "⚡ Installing triggers..."
  mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB" < triggers.sql
  echo "✅ Triggers installed!"
else
  echo "⚠️ Skipping triggers installation."
fi

# ---------------------------
# Setup Cron Jobs
# ---------------------------
echo ""
echo "⏰ Setting up cron jobs..."

CRON_TMP=$(mktemp)

crontab -l 2>/dev/null > "$CRON_TMP" || true

grep -v "$INSTALL_DIR/pasarguard_admin_report.py" "$CRON_TMP" > "$CRON_TMP.clean" || true
mv "$CRON_TMP.clean" "$CRON_TMP"

echo "TZ=$TZ" >> "$CRON_TMP"

echo "5 0 * * * $INSTALL_DIR/.venv/bin/python $INSTALL_DIR/pasarguard_admin_report.py >> /var/log/pasarguard_admin_report.log 2>&1" >> "$CRON_TMP"
echo "10 0 * * 6 $INSTALL_DIR/.venv/bin/python $INSTALL_DIR/pasarguard_admin_report.py weekly >> /var/log/pasarguard_weekly.log 2>&1" >> "$CRON_TMP"
echo "15 0 1 * * $INSTALL_DIR/.venv/bin/python $INSTALL_DIR/pasarguard_admin_report.py monthly >> /var/log/pasarguard_monthly.log 2>&1" >> "$CRON_TMP"

crontab "$CRON_TMP"
rm "$CRON_TMP"

echo "✅ Cron jobs installed!"

# ---------------------------
# Test Run
# ---------------------------
echo ""
echo "✅ Installation finished!"
echo ""
read -rp "Run daily test now? (y/n): " RUN_TEST
if [[ "$RUN_TEST" == "y" || "$RUN_TEST" == "Y" ]]; then
  echo "🚀 Running daily report test..."
  "$INSTALL_DIR/.venv/bin/python" "$INSTALL_DIR/pasarguard_admin_report.py"
fi

echo ""
echo "🎉 Done!"
