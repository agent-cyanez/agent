#!/usr/bin/env bash
# Vela's email interface — check inbox, read messages, send mail.
# Uses IMAP/SMTP via Python with Gmail app password from .env.
#
# Usage:
#   email.sh check                     — list recent unread messages
#   email.sh read <message_id>         — read a specific message by ID
#   email.sh send <to> <subject> <body> — send an email
#   email.sh count                     — count unread messages

set -euo pipefail

VELA_DIR="/home/vela/agent"
set -a
source "$VELA_DIR/.env"
set +a

if [[ -z "${GMAIL_ADDRESS:-}" || -z "${GMAIL_APP_PASSWORD:-}" ]]; then
    echo "Error: GMAIL_ADDRESS and GMAIL_APP_PASSWORD must be set in .env" >&2
    exit 1
fi

ACTION="${1:-check}"
shift || true

python3 - "$ACTION" "$@" <<'PYEOF'
import imaplib
import smtplib
import email
from email.mime.text import MIMEText
from email.header import decode_header
import os
import sys
import json
from datetime import datetime

ADDRESS = os.environ["GMAIL_ADDRESS"]
APP_PASSWORD = os.environ["GMAIL_APP_PASSWORD"]

def decode_subject(msg):
    subject = msg.get("Subject", "(no subject)")
    decoded_parts = decode_header(subject)
    parts = []
    for part, charset in decoded_parts:
        if isinstance(part, bytes):
            parts.append(part.decode(charset or "utf-8", errors="replace"))
        else:
            parts.append(part)
    return "".join(parts)

def get_body(msg):
    if msg.is_multipart():
        for part in msg.walk():
            ct = part.get_content_type()
            if ct == "text/plain" and "attachment" not in str(part.get("Content-Disposition", "")):
                payload = part.get_payload(decode=True)
                charset = part.get_content_charset() or "utf-8"
                return payload.decode(charset, errors="replace")
        for part in msg.walk():
            ct = part.get_content_type()
            if ct == "text/html" and "attachment" not in str(part.get("Content-Disposition", "")):
                payload = part.get_payload(decode=True)
                charset = part.get_content_charset() or "utf-8"
                return f"[HTML content]\n{payload.decode(charset, errors='replace')}"
    else:
        payload = msg.get_payload(decode=True)
        charset = msg.get_content_charset() or "utf-8"
        return payload.decode(charset, errors="replace") if payload else ""
    return ""

def cmd_check():
    imap = imaplib.IMAP4_SSL("imap.gmail.com")
    imap.login(ADDRESS, APP_PASSWORD)
    imap.select("INBOX")
    status, data = imap.search(None, "UNSEEN")
    msg_ids = data[0].split() if data[0] else []
    if not msg_ids:
        print("No unread messages.")
        imap.logout()
        return
    recent = msg_ids[-20:]
    print(f"{len(msg_ids)} unread message(s). Showing latest {len(recent)}:\n")
    for mid in reversed(recent):
        status, msg_data = imap.fetch(mid, "(BODY.PEEK[HEADER])")
        raw = msg_data[0][1]
        msg = email.message_from_bytes(raw)
        subject = decode_subject(msg)
        sender = msg.get("From", "unknown")
        date = msg.get("Date", "unknown")
        print(f"  ID: {mid.decode()}  From: {sender}")
        print(f"  Subject: {subject}")
        print(f"  Date: {date}")
        print()
    imap.logout()

def cmd_read(msg_id):
    imap = imaplib.IMAP4_SSL("imap.gmail.com")
    imap.login(ADDRESS, APP_PASSWORD)
    imap.select("INBOX")
    status, msg_data = imap.fetch(msg_id.encode(), "(RFC822)")
    if status != "OK":
        print(f"Error: could not fetch message {msg_id}")
        imap.logout()
        return
    raw = msg_data[0][1]
    msg = email.message_from_bytes(raw)
    subject = decode_subject(msg)
    sender = msg.get("From", "unknown")
    date = msg.get("Date", "unknown")
    body = get_body(msg)
    print(f"From: {sender}")
    print(f"Subject: {subject}")
    print(f"Date: {date}")
    print(f"\n{body}")
    imap.logout()

def cmd_send(to, subject, body):
    outbox_path = os.path.join(os.environ.get("VELA_DIR", "/home/vela/agent"), "data/outbox.jsonl")
    msg = MIMEText(body)
    msg["Subject"] = subject
    msg["From"] = ADDRESS
    msg["To"] = to
    smtp = smtplib.SMTP_SSL("smtp.gmail.com", 465)
    smtp.login(ADDRESS, APP_PASSWORD)
    smtp.send_message(msg)
    smtp.quit()
    print(f"Sent to {to}: {subject}")
    entry = {
        "timestamp": datetime.now().isoformat(),
        "channel": "email",
        "to": to,
        "subject": subject,
        "message": body
    }
    with open(outbox_path, "a") as f:
        f.write(json.dumps(entry) + "\n")

def cmd_count():
    imap = imaplib.IMAP4_SSL("imap.gmail.com")
    imap.login(ADDRESS, APP_PASSWORD)
    imap.select("INBOX")
    status, data = imap.search(None, "UNSEEN")
    msg_ids = data[0].split() if data[0] else []
    print(len(msg_ids))
    imap.logout()

action = sys.argv[1]
args = sys.argv[2:]

if action == "check":
    cmd_check()
elif action == "read":
    if not args:
        print("Usage: email.sh read <message_id>", file=sys.stderr)
        sys.exit(1)
    cmd_read(args[0])
elif action == "send":
    if len(args) < 3:
        print("Usage: email.sh send <to> <subject> <body>", file=sys.stderr)
        sys.exit(1)
    cmd_send(args[0], args[1], " ".join(args[2:]))
elif action == "count":
    cmd_count()
else:
    print(f"Unknown action: {action}", file=sys.stderr)
    sys.exit(1)
PYEOF
