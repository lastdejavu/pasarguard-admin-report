✅ README.md (کل فایل را کامل پاک کن و این را جایگزین کن)
PasarGuard Admin Report 📊

PasarGuard Admin Report یک ابزار گزارش‌گیری دقیق و ضد ضرر مالی برای PasarGuard / Marzban Panel است که به‌صورت خودکار گزارش‌های روزانه / هفتگی / ماهانه را از دیتابیس می‌خواند و در تلگرام ارسال می‌کند.

✅ هدف اصلی: جلوگیری از ضرر مالی
✅ چون هرگونه ساخت کاربر جدید، افزایش حجم، ریست مصرف، و نامحدود کردن حجم (Unlimited) در گزارش‌ها ثبت و نمایش داده می‌شود.

✨ امکانات اصلی
✅ گزارش روزانه (Daily)

برای هر ادمین به‌صورت جداگانه ارسال می‌شود و شامل موارد زیر است:

ساخت کاربر جدید (INSERT) → محاسبه کامل حجم ساخته‌شده

افزایش حجم کاربر (CHANGE_LIMIT) → محاسبه فقط اختلاف حجم جدید و قبلی (فقط اگر مثبت باشد)

ریست مصرف (RESET_USAGE) → محاسبه کامل حجم پلن (چون کاربر دوباره حجم کامل گرفته)

نامحدود کردن حجم (UNLIMITED) → نمایش به صورت unlimited

افزایش زمان (CHANGE_EXPIRE) → فقط نمایش extend (هزینه حجمی ندارد)

اکشن‌های UPDATE و DELETE → در محاسبه مالی لحاظ نمی‌شوند

✅ گزارش هفتگی (Weekly)

بازه زمانی: شنبه تا جمعه

برای همه ادمین‌ها در یک پیام ارسال می‌شود

علاوه بر حجم، تعداد کاربران unlimited و لیست آن‌ها نمایش داده می‌شود

✅ گزارش ماهانه (Monthly)

بازه زمانی: ماه شمسی قبلی

در روز اول هر ماه شمسی اجرا می‌شود

حجم کلی هر ادمین + unlimited‌ها نمایش داده می‌شود

✅ قوانین محاسبه دقیق (ضد ضرر مالی)

این اسکریپت فقط اکشن‌هایی را محاسبه می‌کند که اثر مالی دارند:

Action در دیتابیس	معنی	محاسبه مالی
INSERT	ساخت کاربر جدید	کل data_limit_new
CHANGE_LIMIT	افزایش/تغییر حجم	فقط new - old اگر مثبت باشد
RESET_USAGE	ریست مصرف	کل data_limit_new
UNLIMITED	نامحدود شدن حجم	فقط نمایش unlimited
CHANGE_EXPIRE	افزایش زمان	فقط نمایش extend
UPDATE	آپدیت سیستمی	نادیده گرفته می‌شود
DELETE	حذف کاربر	نادیده گرفته می‌شود

✅ Unlimited حجمی زمانی است که data_limit_new = 0 یا NULL باشد.
⚠️ Unlimited زمانی (expire) مهم نیست.

📌 نمونه خروجی (Example Output)
✅ گزارش روزانه
Daily report - 1404-10-06
Admin: admin58586

- ali: +50.00 GB
- reza2022: unlimited
- m12: +20.00 GB | reset
- userx: extend

Total: 70.00 GB

Unlimited users:
reza2022

✅ خروجی خلاصه روزانه
Summary - 1404-10-06

Admins:
- admin58586: 70.00 GB | unlimited: 1
- cheaterin: 0.00 GB | unlimited: 1
- router: 250.00 GB | unlimited: 0

Total all: 320.00 GB | unlimited total: 2

🚀 نصب سریع (پیشنهادی)

✅ فقط با ۳ دستور نصب می‌شود:

git clone https://github.com/lastdejavu/pasarguard-admin-report.git
cd pasarguard-admin-report
sudo bash install.sh

✅ install.sh چه کارهایی انجام می‌دهد؟

نصب‌کننده به صورت خودکار:

پکیج‌های ضروری را نصب می‌کند (python, pip, venv, cron, mysql-client)

پروژه را در مسیر استاندارد /opt/pasarguard-admin-report نصب می‌کند

Virtualenv می‌سازد و requirements.txt را نصب می‌کند

با Wizard، فایل .env را می‌سازد

Cron Job ها را اضافه می‌کند (Daily/Weekly/Monthly)

(اختیاری) Trigger های دیتابیس را از triggers.sql نصب می‌کند

(اختیاری) یک تست اجرا می‌کند

⚙️ تنظیمات (Configuration)

در زمان نصب، از شما این موارد پرسیده می‌شود:

MySQL Host / Port / Username / Password / Database

Telegram Bot Token

Telegram Chat ID

Timezone (پیش‌فرض: Asia/Tehran)

تنظیمات در فایل .env ذخیره می‌شود:

MYSQL_HOST=127.0.0.1
MYSQL_PORT=3306
MYSQL_USER=root
MYSQL_PASS=YOUR_PASSWORD
MYSQL_DB=pasarguard

TELEGRAM_BOT_TOKEN=YOUR_BOT_TOKEN
TELEGRAM_CHAT_ID=YOUR_CHAT_ID

TZ=Asia/Tehran

⏰ Cron Jobs (زمان‌بندی خودکار)

بعد از نصب، کرون‌های زیر اضافه می‌شود:

Daily → هر روز ساعت 00:05

Weekly → هر شنبه ساعت 00:10

Monthly → روز ۱ هر ماه ساعت 00:15

برای مشاهده کرون‌ها:

crontab -l

⚠️ Trigger های دیتابیس (خیلی مهم)

این پروژه برای گزارش دقیق نیاز دارد تغییرات جدول users داخل جدول users_logs ثبت شود.

✅ اگر پنل شما به صورت پیش‌فرض users_logs را کامل پر نمی‌کند، باید Trigger ها نصب شوند.
📌 فایل آماده در پروژه وجود دارد: triggers.sql

نصب Trigger ها (دستی)
mysql -u root -p -h 127.0.0.1 -D pasarguard < triggers.sql


✅ یا هنگام اجرای install.sh، اگر گزینه نصب Trigger را تایید کنید، خودش نصب می‌کند.

🧪 اجرای دستی برای تست
cd /opt/pasarguard-admin-report
source .venv/bin/activate

python pasarguard_admin_report.py
python pasarguard_admin_report.py weekly
python pasarguard_admin_report.py monthly

📄 مسیر لاگ‌ها

Daily log: /var/log/pasarguard_admin_report.log

Weekly log: /var/log/pasarguard_weekly.log

Monthly log: /var/log/pasarguard_monthly.log

🛠️ رفع خطاهای رایج
❌ خطای MySQL Connection refused

یعنی روی همین سرور، MySQL روی پورت 3306 در حال اجرا نیست (یا دیتابیس روی سرور دیگری است).

بررسی پورت:

ss -tulnp | grep 3306


اگر دیتابیس روی سرور دیگری است، مقدار MYSQL_HOST را IP همان سرور قرار دهید.

📌 License
MIT License ✅
Use it freely and share improvements.
✅ triggers.sql (حرفه‌ای/استاندارد — جایگزین کل triggers.sql کن)

این نسخه هم Drop دارد هم DELIMITER درست دارد و هم UNLIMITED را دقیق ثبت می‌کند (وقتی data_limit بشود NULL یا 0).

-- PasarGuard Admin Report - Triggers
-- This script creates triggers to log INSERT/UPDATE/DELETE on `users` into `users_logs`

DELIMITER $$

DROP TRIGGER IF EXISTS `InsertLog` $$
DROP TRIGGER IF EXISTS `UpdateLog` $$
DROP TRIGGER IF EXISTS `DeleteLog` $$

CREATE TRIGGER `InsertLog`
AFTER INSERT ON `users`
FOR EACH ROW
BEGIN
  INSERT INTO users_logs (
      admin_id,
      user_id,
      data_limit_old,
      data_limit_new,
      expire_old,
      expire_new,
      used_traffic_old,
      used_traffic_new,
      action,
      log_date
  )
  VALUES (
      NEW.admin_id,
      NEW.id,
      NULL,
      NEW.data_limit,
      NULL,
      NEW.expire,
      NULL,
      NEW.used_traffic,
      'INSERT',
      NOW()
  );
END $$

CREATE TRIGGER `UpdateLog`
AFTER UPDATE ON `users`
FOR EACH ROW
BEGIN
  INSERT INTO users_logs (
      admin_id,
      user_id,
      data_limit_old,
      data_limit_new,
      expire_old,
      expire_new,
      used_traffic_old,
      used_traffic_new,
      action,
      log_date
  )
  VALUES (
      NEW.admin_id,
      NEW.id,
      OLD.data_limit,
      NEW.data_limit,
      OLD.expire,
      NEW.expire,
      OLD.used_traffic,
      NEW.used_traffic,
      CASE
          WHEN (OLD.data_limit <> NEW.data_limit) AND (NEW.data_limit IS NULL OR NEW.data_limit = 0) THEN 'UNLIMITED'
          WHEN OLD.data_limit <> NEW.data_limit THEN 'CHANGE_LIMIT'
          WHEN OLD.expire <> NEW.expire THEN 'CHANGE_EXPIRE'
          WHEN OLD.used_traffic <> NEW.used_traffic AND NEW.used_traffic = 0 THEN 'RESET_USAGE'
          ELSE 'UPDATE'
      END,
      NOW()
  );
END $$

CREATE TRIGGER `DeleteLog`
AFTER DELETE ON `users`
FOR EACH ROW
BEGIN
  INSERT INTO users_logs (
      admin_id,
      user_id,
      data_limit_old,
      data_limit_new,
      expire_old,
      expire_new,
      used_traffic_old,
      used_traffic_new,
      action,
      log_date
  )
  VALUES (
      OLD.admin_id,
      OLD.id,
      OLD.data_limit,
      NULL,
      OLD.expire,
      NULL,
      OLD.used_traffic,
      NULL,
      'DELETE',
      NOW()
  );
END $$

DELIMITER ;
