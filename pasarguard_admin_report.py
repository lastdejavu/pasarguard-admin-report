#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
PasarGuard Admin Report
======================

Accurate accounting for admins based on users_logs table.

Rules:
- INSERT: counts full data_limit_new
- RESET_USAGE: counts full data_limit_new (full package again)
- CHANGE_LIMIT: counts only positive diff (new-old)
- Unlimited: detects data_limit_new == 0 OR data_limit_new becomes NULL (unlimited set)
- UPDATE is not ignored because UPDATE can mean Unlimited conversion in some cases.
- CHANGE_EXPIRE: only shows extend flag (not counted in GB)

Outputs:
- Daily per-admin report
- Daily summary (all admins)
- Weekly summary (all admins + unlimited users list)
- Monthly summary (all admins + unlimited users list)
"""

import os
import sys
import time
import pymysql
import requests
import jdatetime
from datetime import datetime, timedelta
from collections import defaultdict
from dotenv import load_dotenv

# ==========================
# Load Config (.env)
# ==========================

load_dotenv()

MYSQL_CONFIG = {
    "host": os.getenv("MYSQL_HOST", "127.0.0.1"),
    "port": int(os.getenv("MYSQL_PORT", "3306")),
    "user": os.getenv("MYSQL_USER", "root"),
    "password": os.getenv("MYSQL_PASSWORD", ""),
    "database": os.getenv("MYSQL_DB", "pasarguard"),
    "charset": "utf8mb4",
    "autocommit": True,
}

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "").strip()

TIMEZONE_OFFSET = float(os.getenv("TIMEZONE_OFFSET", "3.5"))
TELEGRAM_DELAY_SEC = int(os.getenv("TELEGRAM_DELAY_SEC", "2"))

BYTES_IN_GB = 1024 ** 3

IRAN_OFFSET = timedelta(hours=int(TIMEZONE_OFFSET), minutes=30 if TIMEZONE_OFFSET % 1 else 0)


# ==========================
# Telegram helpers
# ==========================

def send_telegram(text: str):
    """Send message to Telegram bot"""
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        print("[WARN] Telegram config missing, printing instead:\n")
        print(text)
        return

    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    payload = {
        "chat_id": TELEGRAM_CHAT_ID,
        "text": text,
    }

    try:
        resp = requests.post(url, json=payload, timeout=15)
        if not resp.ok:
            print("[ERROR] Telegram send failed:", resp.text)
    except Exception as e:
        print("[ERROR] Telegram exception:", e)


# ==========================
# Date Helpers
# ==========================

def now_iran():
    return datetime.utcnow() + IRAN_OFFSET


def get_iran_today_date():
    return now_iran().date()


def gregorian_to_jalali_str(d):
    jd = jdatetime.date.fromgregorian(date=d)
    return jd.strftime("%Y-%m-%d")


def get_last_week_range():
    """
    Return start_date, end_date for last week (Saturday–Friday).
    Assumes weekly runs on Saturday.
    """
    today = get_iran_today_date()
    last_friday = today - timedelta(days=1)
    last_saturday = last_friday - timedelta(days=6)
    return last_saturday, last_friday


def jalali_prev_month_range(j_today):
    """Return (start_g, end_g, label) for previous Jalali month."""
    if j_today.month == 1:
        prev_year = j_today.year - 1
        prev_month = 12
    else:
        prev_year = j_today.year
        prev_month = j_today.month - 1

    start_j = jdatetime.date(prev_year, prev_month, 1)
    end_j = jdatetime.date(j_today.year, j_today.month, 1)

    start_g = start_j.togregorian()
    end_g = end_j.togregorian()

    label = f"{prev_year}-{prev_month:02d}"
    return start_g, end_g, label


# ==========================
# DB Helpers
# ==========================

def db_connect():
    return pymysql.connect(
        cursorclass=pymysql.cursors.DictCursor,
        **MYSQL_CONFIG,
    )


def fetch_all_admins():
    conn = None
    try:
        conn = db_connect()
        cur = conn.cursor()
        cur.execute("SELECT id, username FROM admins ORDER BY username;")
        return cur.fetchall()
    finally:
        if conn:
            conn.close()


def fetch_logs_between(start_dt, end_dt):
    """
    Fetch logs between [start_dt, end_dt)
    IMPORTANT: Do NOT ignore UPDATE because UPDATE may contain unlimited changes.
    """
    conn = None
    try:
        conn = db_connect()
        cur = conn.cursor()
        query = """
            SELECT
                a.id        AS admin_id,
                a.username  AS admin_username,
                u.id        AS user_id,
                u.username  AS user_username,
                ul.data_limit_old,
                ul.data_limit_new,
                ul.used_traffic_old,
                ul.used_traffic_new,
                ul.action,
                ul.log_date
            FROM users_logs ul
            JOIN users u ON u.id = ul.user_id
            JOIN admins a ON a.id = ul.admin_id
            WHERE ul.log_date >= %s
              AND ul.log_date < %s
            ORDER BY a.id, u.id, ul.log_date;
        """
        cur.execute(query, (start_dt, end_dt))
        return cur.fetchall()
    finally:
        if conn:
            conn.close()


# ==========================
# Core Billing Logic
# ==========================

def calculate_summaries(rows):
    """
    For each admin & user:
      - INSERT: net += data_limit_new
      - RESET_USAGE: net += data_limit_new
      - CHANGE_LIMIT: if new>old -> net += (new-old)
      - Unlimited: if data_limit_new == 0 OR data_limit_new is NULL AND data_limit_old > 0
    """
    admin_user_logs = defaultdict(lambda: defaultdict(list))

    for r in rows:
        if r["admin_id"] is None or r["user_id"] is None:
            continue
        admin_user_logs[r["admin_id"]][r["user_id"]].append(r)

    summaries = {}

    for admin_id, users_logs in admin_user_logs.items():
        sample = next(iter(users_logs.values()))[0]
        admin_name = sample["admin_username"]

        info = {
            "admin_id": admin_id,
            "admin_username": admin_name,
            "total_bytes": 0,
            "users": [],
            "unlimited_users": set(),
        }

        for user_id, logs in users_logs.items():
            logs = sorted(logs, key=lambda x: x["log_date"])
            user_name = logs[-1]["user_username"]

            net_bytes = 0
            unlimited_flag = False

            for l in logs:
                action = (l.get("action") or "").upper()
                old_limit = l.get("data_limit_old") or 0
                new_limit = l.get("data_limit_new")

                # unlimited detection (new_limit becomes NULL or 0)
                if (new_limit is None and old_limit > 0) or (new_limit == 0):
                    unlimited_flag = True

                if new_limit is None:
                    new_limit = old_limit

                if action == "INSERT":
                    if new_limit > 0:
                        net_bytes += new_limit

                elif action == "RESET_USAGE":
                    if new_limit > 0:
                        net_bytes += new_limit

                elif action == "CHANGE_LIMIT":
                    if new_limit > old_limit:
                        net_bytes += (new_limit - old_limit)

            gb = net_bytes / BYTES_IN_GB if net_bytes else 0

            if unlimited_flag:
                info["unlimited_users"].add(user_name)

            info["users"].append({
                "username": user_name,
                "gb": gb,
                "unlimited": unlimited_flag
            })

            info["total_bytes"] += net_bytes

        summaries[admin_id] = info

    return summaries


# ==========================
# Report Builders
# ==========================

def build_daily_reports(summaries, admins, date_str):
    admin_texts = []
    summary_lines = [f"Summary - {date_str}", "", "Admins:"]

    total_all = 0
    total_unlimited = 0

    map_total = {}
    map_unlimit = {}

    for aid, info in summaries.items():
        map_total[info["admin_username"]] = info["total_bytes"] / BYTES_IN_GB
        map_unlimit[info["admin_username"]] = len(info["unlimited_users"])

    for adm in admins:
        name = adm["username"]
        gb = map_total.get(name, 0.0)
        un = map_unlimit.get(name, 0)
        total_all += gb
        total_unlimited += un

        if un > 0:
            summary_lines.append(f"- {name}: {gb:.2f} GB | unlimited: {un}")
        else:
            summary_lines.append(f"- {name}: {gb:.2f} GB")

    summary_lines.append("")
    summary_lines.append(f"Total all: {total_all:.2f} GB | unlimited total: {total_unlimited}")

    # per-admin detail
    for aid, info in sorted(summaries.items(), key=lambda x: x[1]["admin_username"]):
        if info["total_bytes"] == 0 and len(info["unlimited_users"]) == 0:
            continue

        lines = [f"Daily report - {date_str}", f"Admin: {info['admin_username']}", ""]

        for u in sorted(info["users"], key=lambda x: x["username"]):
            parts = []
            if u["gb"] > 0:
                parts.append(f"+{u['gb']:.2f} GB")
            if u["unlimited"]:
                parts.append("unlimited")

            if parts:
                lines.append(f"- {u['username']}: " + " | ".join(parts))

        lines.append("")
        lines.append(f"Total: {info['total_bytes']/BYTES_IN_GB:.2f} GB")

        if info["unlimited_users"]:
            lines.append("")
            lines.append("Unlimited users:")
            lines.append(", ".join(sorted(info["unlimited_users"])))

        admin_texts.append("\n".join(lines))

    return admin_texts, "\n".join(summary_lines)


def build_weekly_text(summaries, admins, start_date, end_date):
    range_str = f"{gregorian_to_jalali_str(start_date)} -> {gregorian_to_jalali_str(end_date)}"
    lines = ["Weekly summary", f"Range: {range_str}", "", "Admins:"]

    total_all = 0
    total_unlimited = 0

    map_total = {}
    map_unlimit = {}
    map_users = {}

    for aid, info in summaries.items():
        map_total[info["admin_username"]] = info["total_bytes"] / BYTES_IN_GB
        map_unlimit[info["admin_username"]] = len(info["unlimited_users"])
        map_users[info["admin_username"]] = info["unlimited_users"]

    for adm in admins:
        name = adm["username"]
        gb = map_total.get(name, 0)
        un = map_unlimit.get(name, 0)
        total_all += gb
        total_unlimited += un

        if un > 0:
            lines.append(f"- {name}: {gb:.2f} GB | unlimited: {un}")
            lines.append(f"  Unlimited users: {', '.join(sorted(map_users[name]))}")
        else:
            lines.append(f"- {name}: {gb:.2f} GB")

    lines.append("")
    lines.append(f"Total all: {total_all:.2f} GB | unlimited total: {total_unlimited}")
    return "\n".join(lines)


def build_monthly_text(summaries, admins, label):
    lines = [f"Monthly summary (Jalali {label})", "", "Admins:"]

    total_all = 0
    total_unlimited = 0

    map_total = {}
    map_unlimit = {}
    map_users = {}

    for aid, info in summaries.items():
        map_total[info["admin_username"]] = info["total_bytes"] / BYTES_IN_GB
        map_unlimit[info["admin_username"]] = len(info["unlimited_users"])
        map_users[info["admin_username"]] = info["unlimited_users"]

    for adm in admins:
        name = adm["username"]
        gb = map_total.get(name, 0)
        un = map_unlimit.get(name, 0)
        total_all += gb
        total_unlimited += un

        if un > 0:
            lines.append(f"- {name}: {gb:.2f} GB | unlimited: {un}")
            lines.append(f"  Unlimited users: {', '.join(sorted(map_users[name]))}")
        else:
            lines.append(f"- {name}: {gb:.2f} GB")

    lines.append("")
    lines.append(f"Total all: {total_all:.2f} GB | unlimited total: {total_unlimited}")
    return "\n".join(lines)


# ==========================
# Run modes
# ==========================

def run_daily():
    admins = fetch_all_admins()

    today = get_iran_today_date()
    yesterday = today - timedelta(days=1)

    start_dt = datetime.combine(yesterday, datetime.min.time())
    end_dt = datetime.combine(today, datetime.min.time())

    rows = fetch_logs_between(start_dt, end_dt)
    summaries = calculate_summaries(rows)

    date_str = gregorian_to_jalali_str(yesterday)
    texts, summary = build_daily_reports(summaries, admins, date_str)

    for t in texts:
        print(t, "\n" + "=" * 40 + "\n")
        send_telegram(t)
        time.sleep(TELEGRAM_DELAY_SEC)

    send_telegram(summary)
    print(summary)


def run_weekly():
    admins = fetch_all_admins()
    start_date, end_date = get_last_week_range()

    start_dt = datetime.combine(start_date, datetime.min.time())
    end_dt = datetime.combine(end_date + timedelta(days=1), datetime.min.time())

    rows = fetch_logs_between(start_dt, end_dt)
    summaries = calculate_summaries(rows)

    text = build_weekly_text(summaries, admins, start_date, end_date)
    send_telegram(text)
    print(text)


def run_monthly():
    admins = fetch_all_admins()
    today = get_iran_today_date()
    j_today = jdatetime.date.fromgregorian(date=today)

    start_g, end_g, label = jalali_prev_month_range(j_today)

    start_dt = datetime.combine(start_g, datetime.min.time())
    end_dt = datetime.combine(end_g, datetime.min.time())

    rows = fetch_logs_between(start_dt, end_dt)
    summaries = calculate_summaries(rows)

    text = build_monthly_text(summaries, admins, label)
    send_telegram(text)
    print(text)


def main():
    mode = "daily"
    if len(sys.argv) > 1:
        mode = sys.argv[1].lower().strip()

    if mode == "weekly":
        run_weekly()
    elif mode == "monthly":
        run_monthly()
    else:
        run_daily()


if __name__ == "__main__":
    main()
