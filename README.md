# PasarGuard Admin Report (Telegram Daily Digest)

یک گزارش روزانه‌ی جمع‌وجور از فعالیت ادمین‌ها در پنل **PasarGuard** که در تلگرام ارسال می‌شود.

---

## خروجی نمونه

```
1404-10-08
Admin: admin

- amin2580: +10.00 GB
- sami9147: unlimited
- sara69: +120.00 GB

Total: 130.00 GB
```

---

## چه چیزهایی را گزارش می‌کند؟

این پروژه با **Trigger** روی جدول `users` در دیتابیس PasarGuard، رویدادها را در جدول `admin_report_events` ذخیره می‌کند و سپس روزی یک‌بار گزارش را برای هر ادمین جداگانه در تلگرام ارسال می‌کند:

✅ ساخت یوزر محدود (`USER_CREATED`)  
✅ ساخت یوزر نامحدود (`UNLIMITED_CREATED`)  
✅ افزایش حجم (`DATA_LIMIT_CHANGED` فقط افزایش‌ها)  
✅ تبدیل محدود → نامحدود (`LIMIT_TO_UNLIMITED`)  
✅ ریست مصرف (`USAGE_RESET`)  

---

## سیاست مهم مالی (برای جلوگیری از ضرر)

اگر یوزر محدود باشد و ادمین **ریست** کند، این پروژه به صورت پیش‌فرض **کل سقف فعلی یوزر** را شارژ حساب می‌کند.

مثال:
- یوزر سقف 100GB دارد
- 50GB مصرف کرده
- ادمین ریست می‌کند  
✅ در گزارش: **+100GB** حساب می‌شود

این رفتار با ENV قابل تغییر است:
- `CHARGE_FULL_LIMIT_ON_RESET=1` (پیش‌فرض: 1)

---

## نیازمندی‌ها

- PasarGuard باید روی سرور شما نصب شده باشد و MySQL آن **داخل Docker** اجرا شود.
- فایل env پاسارگارد موجود باشد:
  - پیش‌فرض: `/opt/pasarguard/.env`
  - باید شامل:
    - `MYSQL_ROOT_PASSWORD=...`
    - `DB_NAME=...` (اگر نبود، پیش‌فرض `pasarguard`)
- نیازی به نصب MySQL روی خود سرور نیست (اسکریپت از `docker exec` استفاده می‌کند).

---

## نصب با یک خط (One-line Installer)

### حالت تعاملی (از شما توکن و چت آیدی می‌پرسد)
```bash
curl -fsSL https://raw.githubusercontent.com/lastdejavu/pasarguard-admin-report/main/install.sh | sudo bash
```

### حالت بدون سوال (بهترین برای کپی/پیست)
```bash
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN" TELEGRAM_CHAT_ID="YOUR_CHAT_ID" \
curl -fsSL https://raw.githubusercontent.com/lastdejavu/pasarguard-admin-report/main/install.sh | sudo -E bash
```

نکته: حتماً قبلش در تلگرام با بات استارت کنید یا در گروه/کانال اضافه‌اش کنید.

---

## بعد از نصب چه اتفاقی می‌افتد؟

Installer این کارها را انجام می‌دهد:

1) ساخت مسیر:
- `/opt/pasarguard-admin-report`

2) ساخت venv و نصب پکیج‌ها

3) اعمال `triggers.sql` داخل کانتینر MySQL  
(با پسورد root خوانده‌شده از `/opt/pasarguard/.env`)

4) ساخت cron برای ارسال گزارش روز قبل ساعت 00:00 به وقت ایران:
- `/var/log/pasarguard-admin-report.log`

---

## اجرای تست دستی

### تست “امروز” (برای دیباگ سریع)
```bash
sudo /opt/pasarguard-admin-report/.venv/bin/python /opt/pasarguard-admin-report/daily_digest.py today
```

### اجرای حالت اصلی (دیفالت: گزارش دیروز)
```bash
sudo /opt/pasarguard-admin-report/.venv/bin/python /opt/pasarguard-admin-report/daily_digest.py
```

---

## تنظیمات (ENV)

فایل:
- `/opt/pasarguard-admin-report/.env`

کلیدهای مهم:

- `TIMEZONE=Asia/Tehran`
- `TELEGRAM_BOT_TOKEN=...`
- `TELEGRAM_CHAT_ID=...`

آپشن‌ها:

- `SHOW_LIMIT_AFTER_UNLIMITED=1`
  - اگر 1 باشد وقتی محدود→نامحدود شود، نشان می‌دهد: `unlimited (was 30.00 GB)`
  - اگر 0 باشد فقط می‌نویسد: `unlimited`

- `CHARGE_FULL_LIMIT_ON_RESET=1`
  - اگر 1 باشد (پیش‌فرض)، ریست = شارژ کامل سقف فعلی
  - اگر 0 باشد، ریست = شارژ مقدار مصرف قبلی (old_used)

در صورت نیاز به override کانتینر یا مسیر env پاسارگارد:

- `MYSQL_CONTAINER=pasarguard-mysql-1`
- `PASARGUARD_ENV=/opt/pasarguard/.env`

---

## بررسی اینکه Trigger ها نصب شده‌اند

```bash
MYSQL_ROOT_PASSWORD="$(sudo grep -E '^MYSQL_ROOT_PASSWORD=' /opt/pasarguard/.env | cut -d= -f2-)"
DB_NAME="$(sudo grep -E '^DB_NAME=' /opt/pasarguard/.env | cut -d= -f2-)"
[ -z "$DB_NAME" ] && DB_NAME="pasarguard"

sudo docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" pasarguard-mysql-1 mysql -uroot -e "
USE \`$DB_NAME\`;
SHOW TRIGGERS;
SHOW TABLES LIKE 'admin_report_events';
"
```

---

## لاگ‌ها

- Log file:
  - `/var/log/pasarguard-admin-report.log`

نمایش لاگ:
```bash
sudo tail -n 200 /var/log/pasarguard-admin-report.log
```

---

## حذف کامل (Uninstall)

### 1) حذف cron
```bash
sudo crontab -l | sed '/BEGIN pasarguard-admin-report/,/END pasarguard-admin-report/d' | sudo crontab -
```

### 2) حذف فایل‌ها و لاگ
```bash
sudo rm -rf /opt/pasarguard-admin-report
sudo rm -f /var/log/pasarguard-admin-report.log
```

### 3) حذف جدول و trigger ها (اختیاری)
هشدار: این کار تاریخچه را پاک می‌کند.

```bash
MYSQL_ROOT_PASSWORD="$(sudo grep -E '^MYSQL_ROOT_PASSWORD=' /opt/pasarguard/.env | cut -d= -f2-)"
DB_NAME="$(sudo grep -E '^DB_NAME=' /opt/pasarguard/.env | cut -d= -f2-)"
[ -z "$DB_NAME" ] && DB_NAME="pasarguard"

sudo docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" pasarguard-mysql-1 mysql -uroot -e "
USE \`$DB_NAME\`;
DROP TRIGGER IF EXISTS trg_report_user_create;
DROP TRIGGER IF EXISTS trg_report_user_update;
DROP TABLE IF EXISTS admin_report_events;
"
```

---

## نکات امنیتی

- Bot Token را private نگه دارید.
- Installer توکن را validate می‌کند (getMe) و یک پیام تست هم می‌فرستد.

---

## Troubleshooting

### 1) پیام نمی‌آید ولی ping می‌آید
معمولاً یعنی دیتابیس برای بازه موردنظر event ندارد.

برای تست از `today` استفاده کنید:
```bash
sudo /opt/pasarguard-admin-report/.venv/bin/python /opt/pasarguard-admin-report/daily_digest.py today
```

### 2) کانتینر MySQL پیدا نمی‌شود
نام کانتینر را مشخص کنید:
```bash
MYSQL_CONTAINER="your-mysql-container" TELEGRAM_BOT_TOKEN="..." TELEGRAM_CHAT_ID="..." \
curl -fsSL https://raw.githubusercontent.com/lastdejavu/pasarguard-admin-report/main/install.sh | sudo -E bash
```

### 3) DB_NAME داخل /opt/pasarguard/.env نبود
مشکلی نیست؛ پیش‌فرض `pasarguard` است.

---


