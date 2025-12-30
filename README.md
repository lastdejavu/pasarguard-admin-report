# گزارش ادمین‌های پنل PasarGuard (Telegram Daily Digest)

این پروژه برای پنل **PasarGuard** طراحی شده تا هر تغییری که توسط ادمین‌ها روی کاربران انجام می‌شود (ساخت کاربر، افزایش حجم، ساخت/تبدیل به Unlimited، ریست مصرف) ثبت شود و **هر شب ساعت ۰۰:۰۰ به وقت ایران** یک گزارش **جمع‌وجور و حرفه‌ای** به تلگرام شما ارسال کند.

> هدف اصلی: **جلوگیری از ضرر مالی** با ثبت دقیق تغییرات حجم/Unlimited و ریست مصرف توسط ادمین‌ها.

---

## خروجی پیام در تلگرام (نمونه)

```text
1404-10-08
Admin: admin

- amin2580: +10.00 GB
- sami9147: unlimited
- sara69: +120.00 GB

Total: 140.00 GB
```

- تاریخ به صورت **شمسی** نمایش داده می‌شود.
- گزارش **برای هر ادمین جداگانه** ارسال می‌شود.
- پیام‌ها **شلوغ نیستند** و فقط موارد مهم را نمایش می‌دهند.

---

## قابلیت‌ها

- ثبت خودکار رویدادها با **MySQL Trigger** (بدون نیاز به FUNCTION و بدون نیاز به تغییر تنظیمات خطرناک مثل `log_bin_trust_function_creators`)
- پشتیبانی از رویدادهای مهم:
  - `USER_CREATED` ساخت کاربر محدود
  - `UNLIMITED_CREATED` ساخت کاربر Unlimited
  - `DATA_LIMIT_CHANGED` افزایش حجم (و در صورت نیاز کاهش هم قابل نمایش است)
  - `LIMIT_TO_UNLIMITED` تبدیل محدود → Unlimited (به‌عنوان رویداد مهم و حساس)
  - `UNLIMITED_TO_LIMIT` تبدیل Unlimited → محدود (برای کنترل)
  - `USAGE_RESET` ریست مصرف
- گزارش روزانه به تفکیک هر ادمین
- جمع‌بندی `Total` (جمع افزایش حجم‌های همان روز برای همان ادمین)
- نصب بسیار ساده با **یک خط** (One‑Line Installer)

---

## پیش‌نیازها

1) پنل PasarGuard شما باید به صورت **Docker Compose** نصب شده باشد.  
2) فایل env پنل معمولاً اینجاست:

- `/opt/pasarguard/.env`

3) دیتابیس MySQL باید داخل کانتینر (مثلاً `pasarguard-mysql-1`) فعال باشد.  
> این پروژه فرض می‌کند دیتابیس PasarGuard **داخل Docker** است (نه نصب مستقیم روی سیستم).

---

## نصب با یک خط (پیشنهادی)

روی سرور اجرا کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/lastdejavu/pasarguard-admin-report/main/install.sh | sudo bash
```

نصب‌کننده از شما موارد زیر را می‌پرسد:
- Timezone (پیش‌فرض: `Asia/Tehran`)
- Telegram Bot Token
- Telegram Chat ID

✅ سپس به صورت خودکار:
- اسکریپت را در مسیر `/opt/pasarguard-admin-report` نصب می‌کند
- `daily_digest.py` را می‌سازد
- تریگرهای MySQL را اعمال می‌کند
- کرون (Cron) را برای اجرای هر شب ساعت ۰۰:۰۰ تنظیم می‌کند
- توکن ربات را صحت‌سنجی می‌کند (با `getMe`)

---

## راه‌اندازی تلگرام

### 1) ساخت Bot Token
- به `@BotFather` پیام دهید و یک Bot بسازید
- توکن را دریافت کنید (مثل: `123456:ABC...`)

### 2) گرفتن Chat ID
- اگر می‌خواهید گزارش به PV خودتان بیاید:
  - به Bot پیام بدهید
  - سپس از یکی از ابزارهای دریافت Chat ID استفاده کنید یا از دستور تست داخل README استفاده کنید (پایین‌تر)

> اگر می‌خواهید داخل گروه/کانال ارسال شود، ابتدا Bot را عضو کنید و دسترسی بدهید.

---

## اجرای تست دستی

بعد از نصب:

```bash
sudo /opt/pasarguard-admin-report/.venv/bin/python /opt/pasarguard-admin-report/daily_digest.py
```

نکته مهم:  
به صورت پیش‌فرض این اسکریپت **گزارش روز قبل** را می‌فرستد.  
پس اگر «دیروز» هیچ رویدادی نداشته باشید، ممکن است چیزی ارسال نشود (برای جلوگیری از شلوغی).

---

## کرون (Cron) نصب‌شده

نصب‌کننده این کرون را اضافه می‌کند:

```cron
# BEGIN pasarguard-admin-report
0 0 * * * TZ=Asia/Tehran /opt/pasarguard-admin-report/.venv/bin/python /opt/pasarguard-admin-report/daily_digest.py >> /var/log/pasarguard-admin-report.log 2>&1
# END pasarguard-admin-report
```

لاگ‌ها در این مسیر ذخیره می‌شوند:

- `/var/log/pasarguard-admin-report.log`

برای مشاهده لاگ:

```bash
sudo tail -n 200 /var/log/pasarguard-admin-report.log
```

---

## ساختار دیتابیس و نحوه کار

این پروژه یک جدول جدید ایجاد می‌کند:

- `admin_report_events`

و روی جدول اصلی کاربران (`users`) دو Trigger می‌گذارد:

- بعد از INSERT → ثبت ساخت کاربر (limited/unlimited)
- بعد از UPDATE → ثبت تغییر حجم/تبدیل به unlimited/ریست مصرف

سپس `daily_digest.py` هر روز رویدادهای بازهٔ زمانی روز قبل را می‌خواند و پیام را به تلگرام می‌فرستد.

---

## سیاست محاسبه «ریست مصرف» (برای جلوگیری از ضرر)

### سوال مهم:
اگر کاربر **۱۰۰GB حجم داشته** و **۵۰GB مصرف کرده** و ادمین **ریست کند**، چه مقدار باید «حساب» شود؟

✅ پاسخ این پروژه (طبق خواسته شما):
- در رویداد `USAGE_RESET` مقدار **حجم کامل کاربر در همان لحظه** به عنوان هزینه/حساب شدن در نظر گرفته می‌شود.
- یعنی اگر کاربر ۱۰۰GB داشت، ریست = **۱۰۰GB حساب می‌شود** (نه ۵۰GB).

این دقیقاً برای جلوگیری از ضرر است:  
ادمین با ریست نمی‌تواند باعث شود «مصرف واقعی» دیده نشود.

> اگر شما بعداً خواستید سیاست را تغییر دهید، می‌توانیم آن را به‌صورت گزینه (Env) قابل کنترل کنیم.

---

## تنظیمات (ENV)

فایل تنظیمات اینجاست:

- `/opt/pasarguard-admin-report/.env`

موارد مهم:
- `TIMEZONE`
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`
- تنظیمات اتصال MySQL (در حالت پیش‌فرض از PasarGuard خوانده می‌شود)

---

## پاک کردن کامل (Uninstall)

برای پاک کردن کرون و فایل‌ها:

```bash
sudo crontab -l | sed '/BEGIN pasarguard-admin-report/,/END pasarguard-admin-report/d' | sudo crontab -
sudo rm -rf /opt/pasarguard-admin-report
sudo rm -f /var/log/pasarguard-admin-report.log
```

اگر می‌خواهید جدول/تریگرها هم حذف شوند (اختیاری):

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

## سوالات رایج و رفع مشکل

### 1) چرا پیام ارسال نمی‌شود؟
- اگر دیروز هیچ رویدادی نبود، عمداً پیام ارسال نمی‌شود (برای جلوگیری از شلوغی).
- توکن و Chat ID را بررسی کنید:

```bash
BOT="$(sudo grep -E '^TELEGRAM_BOT_TOKEN=' /opt/pasarguard-admin-report/.env | cut -d= -f2-)"
curl -s "https://api.telegram.org/bot$BOT/getMe" | head
```

### 2) خطای 404 در تلگرام
معمولاً به این معنی است که **توکن اشتباه/کپی خراب** است (مثلاً دوبار چسبانده شده).  
توکن را دوباره درست وارد کنید.

### 3) چرا MySQL روی سیستم نصب نیست؟
این پروژه فرض می‌کند MySQL داخل Docker است (همان‌طور که اکثر نصب‌های PasarGuard هستند).  
بنابراین نیازی به نصب MySQL روی خود سیستم نیست.

---

## نکات امنیتی

- توکن ربات را **در اختیار کسی قرار ندهید**.
- اگر Bot Token لو رفت، از BotFather توکن را **ریست** کنید.
- بهتر است گزارش‌ها فقط به PV شما یا گروه خصوصی ارسال شوند.

---

## لایسنس
MIT

---

