#!/usr/bin/env python3
"""Cancel Cal.diy bookings whose number answer is above a limit.

Cal.diy POSTs a signed webhook for every new booking. If the answer to the
booking question FIELD is greater than MAX_VALUE, this cancels the booking
through Cal's own /api/cancel endpoint with a stated reason, which Cal emails
to the attendee. Answers at or below the limit, and bookings without a usable
number, are left alone.

An applicant cancelled this way is remembered by email (REJECTED_FILE). If the
same person books again, that booking is cancelled too, whatever they answer
this time, with a second reason. Only people this script cancelled for the
number are remembered; everyone else may book as often as they like. Emails are
compared lowercased, without a +tag, and without dots for Gmail addresses.

Environment:
  CAL_URL             where this script can reach Cal, e.g. http://calcom:3000
  WEBHOOK_SECRET      the secret entered when creating the webhook in Cal
  FIELD               the question's Identifier (Advanced > Booking questions)
  MAX_VALUE           answers above this are cancelled
  REASON_FILE         optional; a text file with the cancellation reason, read on
                      every cancellation so editing it needs no restart
  REASON              optional; the reason itself when there is no REASON_FILE
                      ({value} and {max} are replaced by the answer and the limit)
  REJECTED_FILE       optional; turns on the repeat-applicant block. One email
                      per line, anything after a # is a note. Created if missing.
                      Edit it by hand to add or remove people; it is re-read on
                      every booking, so no restart is needed.
  REPEAT_REASON_FILE  optional; the reason for a repeat applicant, like REASON_FILE
  REPEAT_REASON       optional; the reason itself when there is no REPEAT_REASON_FILE
  PORT, BIND          optional; default 8787 and 127.0.0.1
"""
import hashlib
import hmac
import json
import math
import os
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CAL_URL = os.environ["CAL_URL"].rstrip("/")
SECRET = os.environ["WEBHOOK_SECRET"].encode()
FIELD = os.environ["FIELD"]
MAX_VALUE = float(os.environ["MAX_VALUE"])
REASON_FILE = os.environ.get("REASON_FILE", "")
REASON = os.environ.get("REASON", "Sorry, we can only take bookings for up to {max} (you entered {value}).")
REJECTED_FILE = os.environ.get("REJECTED_FILE", "")
REPEAT_REASON_FILE = os.environ.get("REPEAT_REASON_FILE", "")
REPEAT_REASON = os.environ.get("REPEAT_REASON", "Sorry, we have already reviewed your application.")
TRIGGERS = {"BOOKING_CREATED", "BOOKING_REQUESTED"}   # REQUESTED = event types that need confirmation
LOCK = threading.Lock()                               # one writer at a time for REJECTED_FILE


def log(msg):
    print(msg, flush=True)


def load_reason(path, fallback):
    text = fallback
    if path:
        with open(path, encoding="utf-8") as f:
            text = f.read().strip()
    if not text:
        raise ValueError("a cancellation reason is empty")
    return text


def reason_text(value, limit):
    return load_reason(REASON_FILE, REASON).replace("{value}", value).replace("{max}", limit)


def parse_number(raw):
    """The answer as a finite float, or None. A leading $ is tolerated."""
    try:
        value = float(str(raw).strip().lstrip("$").strip())
    except ValueError:
        return None
    return value if math.isfinite(value) else None


def normalize_email(raw):
    """The mailbox behind an address, or None: lowercase, no +tag, no dots for Gmail."""
    local, _, domain = str(raw or "").strip().lower().partition("@")
    local = local.split("+")[0]
    if domain in ("gmail.com", "googlemail.com"):
        local, domain = local.replace(".", ""), "gmail.com"
    return f"{local}@{domain}" if local and domain else None


def booker_email(payload):
    entry = (payload.get("responses") or {}).get("email")
    raw = entry.get("value") if isinstance(entry, dict) else None
    if not raw:
        attendees = payload.get("attendees") or []
        raw = attendees[0].get("email") if attendees and isinstance(attendees[0], dict) else None
    return normalize_email(raw)


def was_rejected(email):
    try:
        with open(REJECTED_FILE, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return False
    except OSError as e:
        log(f"could not read {REJECTED_FILE}, skipping the repeat check: {e!r}")
        return False
    for line in lines:
        token = line.split("#", 1)[0].split()
        if token and normalize_email(token[0]) == email:
            return True
    return False


def remember(email, value):
    try:
        with LOCK, open(REJECTED_FILE, "a", encoding="utf-8") as f:
            f.write(f"{email}  # {time.strftime('%Y-%m-%d')}, answered {value:g}\n")
    except OSError as e:
        log(f"could not remember {email} in {REJECTED_FILE}: {e!r}")
        return
    log(f"remembered {email}: a new booking from them is cancelled")


def cancel(uid, organizer_email, reason):
    # Cal's cancel endpoint wants a CSRF token, sent both as a cookie and in the body.
    with urllib.request.urlopen(f"{CAL_URL}/api/csrf", timeout=15) as r:
        token = json.load(r)["csrfToken"]
    body = json.dumps({"uid": uid, "cancellationReason": reason,
                       "cancelledBy": organizer_email, "csrfToken": token}).encode()
    req = urllib.request.Request(f"{CAL_URL}/api/cancel", data=body, method="POST", headers={
        "Content-Type": "application/json", "Cookie": f"calcom.csrf_token={token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


class Hook(BaseHTTPRequestHandler):
    def reply(self, code, text=""):
        self.send_response(code)
        self.end_headers()
        self.wfile.write(text.encode())

    def cancel_and_reply(self, uid, payload, get_reason, what):
        """Cancel the booking and answer Cal. Returns Cal's HTTP status, or None if it failed."""
        try:
            status, text = cancel(uid, payload["organizer"]["email"], get_reason())
        except (OSError, ValueError, KeyError) as e:   # Cal unreachable, bad reason file, unexpected reply
            log(f"{uid}: {what}, but the cancel failed: {e!r}")
            self.reply(502, "cancel failed")
            return None
        log(f"{uid}: {what}, cancel -> HTTP {status} {text[:200]}")
        self.reply(200 if status == 200 else 502, text[:200])
        return status

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        expected = hmac.new(SECRET, raw, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, self.headers.get("X-Cal-Signature-256", "")):
            log("rejected a request with a bad signature - does the webhook's Secret match WEBHOOK_SECRET in auto-cancel.env?")
            return self.reply(401, "bad signature")
        try:
            data = json.loads(raw)
            payload = data["payload"]
        except (ValueError, KeyError):
            return self.reply(400, "not a Cal webhook body")
        if data.get("triggerEvent") not in TRIGGERS:
            return self.reply(200, "ignored trigger")

        uid = payload.get("uid")
        booker = booker_email(payload)

        # Someone this script already cancelled for the number: cancel this one too.
        if REJECTED_FILE and booker and was_rejected(booker):
            self.cancel_and_reply(uid, payload, lambda: load_reason(REPEAT_REASON_FILE, REPEAT_REASON),
                                  f"{booker} was cancelled before, repeat application")
            return

        answers = payload.get("responses") or {}
        entry = answers.get(FIELD)
        value = parse_number(entry.get("value")) if isinstance(entry, dict) else None
        if value is None:
            log(f"{uid}: no usable number in '{FIELD}', left alone (answers in this booking: {sorted(answers)})")
            return self.reply(200, "no number")
        if not value > MAX_VALUE:
            log(f"{uid}: {value:g} <= {MAX_VALUE:g}, kept")
            return self.reply(200, "ok")

        status = self.cancel_and_reply(uid, payload, lambda: reason_text(f"{value:g}", f"{MAX_VALUE:g}"),
                                       f"{value:g} > {MAX_VALUE:g}")
        if status == 200 and REJECTED_FILE and booker:   # only people who really were cancelled are remembered
            remember(booker, value)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    # Fail at startup, not at the first booking, if a reason or the data file is unusable.
    reason_text("0", "0")
    if REJECTED_FILE:
        load_reason(REPEAT_REASON_FILE, REPEAT_REASON)
        open(REJECTED_FILE, "a", encoding="utf-8").close()
    addr = (os.environ.get("BIND", "127.0.0.1"), int(os.environ.get("PORT", "8787")))
    repeat = f", repeat applicants blocked via {REJECTED_FILE}" if REJECTED_FILE else ""
    log(f"listening on {addr[0]}:{addr[1]}, cancelling '{FIELD}' > {MAX_VALUE:g} via {CAL_URL}{repeat}")
    ThreadingHTTPServer(addr, Hook).serve_forever()
