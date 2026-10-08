#!/usr/bin/env python3
"""Cancel Cal.diy bookings whose number answer is above a limit.

Cal.diy POSTs a signed webhook for every new booking. If the answer to the
booking question FIELD is greater than MAX_VALUE, this cancels the booking
through Cal's own /api/cancel endpoint with a stated reason, which Cal emails
to the attendee. Answers at or below the limit, and bookings without a usable
number, are left alone.

Environment:
  CAL_URL         where this script can reach Cal, e.g. http://calcom:3000
  WEBHOOK_SECRET  the secret entered when creating the webhook in Cal
  FIELD           the question's Identifier (Advanced > Booking questions)
  MAX_VALUE       answers above this are cancelled
  REASON_FILE     optional; a text file with the cancellation reason, read on
                  every cancellation so editing it needs no restart
  REASON          optional; the reason itself when there is no REASON_FILE
                  ({value} and {max} are replaced by the answer and the limit)
  PORT, BIND      optional; default 8787 and 127.0.0.1
"""
import hashlib
import hmac
import json
import math
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CAL_URL = os.environ["CAL_URL"].rstrip("/")
SECRET = os.environ["WEBHOOK_SECRET"].encode()
FIELD = os.environ["FIELD"]
MAX_VALUE = float(os.environ["MAX_VALUE"])
REASON_FILE = os.environ.get("REASON_FILE", "")
REASON = os.environ.get("REASON", "Sorry, we can only take bookings for up to {max} (you entered {value}).")
TRIGGERS = {"BOOKING_CREATED", "BOOKING_REQUESTED"}   # REQUESTED = event types that need confirmation


def log(msg):
    print(msg, flush=True)


def reason_text(value, limit):
    text = REASON
    if REASON_FILE:
        with open(REASON_FILE, encoding="utf-8") as f:
            text = f.read().strip()
    if not text:
        raise ValueError("the cancellation reason is empty")
    return text.replace("{value}", value).replace("{max}", limit)


def parse_number(raw):
    """The answer as a finite float, or None. A leading $ is tolerated."""
    try:
        value = float(str(raw).strip().lstrip("$").strip())
    except ValueError:
        return None
    return value if math.isfinite(value) else None


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
        answers = payload.get("responses") or {}
        entry = answers.get(FIELD)
        value = parse_number(entry.get("value")) if isinstance(entry, dict) else None
        if value is None:
            log(f"{uid}: no usable number in '{FIELD}', left alone (answers in this booking: {sorted(answers)})")
            return self.reply(200, "no number")
        if not value > MAX_VALUE:
            log(f"{uid}: {value:g} <= {MAX_VALUE:g}, kept")
            return self.reply(200, "ok")

        try:
            status, text = cancel(uid, payload["organizer"]["email"],
                                  reason_text(f"{value:g}", f"{MAX_VALUE:g}"))
        except (OSError, ValueError, KeyError) as e:   # Cal unreachable, bad reason file, unexpected reply
            log(f"{uid}: {value:g} > {MAX_VALUE:g}, but the cancel failed: {e!r}")
            return self.reply(502, "cancel failed")
        log(f"{uid}: {value:g} > {MAX_VALUE:g}, cancel -> HTTP {status} {text[:200]}")
        return self.reply(200 if status == 200 else 502, text[:200])

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    reason_text("0", "0")   # fail at startup, not at the first cancellation, if the reason is unusable
    addr = (os.environ.get("BIND", "127.0.0.1"), int(os.environ.get("PORT", "8787")))
    log(f"listening on {addr[0]}:{addr[1]}, cancelling '{FIELD}' > {MAX_VALUE:g} via {CAL_URL}")
    ThreadingHTTPServer(addr, Hook).serve_forever()
