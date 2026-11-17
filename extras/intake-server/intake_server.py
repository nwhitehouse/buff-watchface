#!/usr/bin/env python3
"""Optional calories-eaten endpoint for the Buff watch face's calorie deficit mode (docs/deficit-mode.md). A standalone
standard-library server (Python 3.11+); the logic is plain functions, so it's easy to move to a serverless function.

  POST /intake   Signed by the iPhone Shortcut; the secret itself is never sent. No body; three headers:
                   X-Intake-Time:      2026-11-07T16:20:31+13:00   (ISO 8601, the phone's local time)
                   X-Intake-In:        1300                        (today's kcal eaten, however Shortcuts formats it)
                   X-Intake-Signature: sha256_hex(time + "|" + in + "|" + SIGNING_SECRET)
                 Rejected if the time is more than 5 minutes off, or not newer than the last accepted push (so a
                 captured request can't be replayed). An empty X-Intake-In (no samples in Health) is accepted but not stored.
  GET  /intake   Authorization: Bearer <READ_TOKEN>  -> {"date", "in", "bmr", "ts", "sent", "days"}     (the watch)
  GET  /healthz  -> "ok"
Tokens are never accepted in the URL.

Config (environment): INTAKE_SIGNING_SECRET, INTAKE_READ_TOKENS (comma-separated: the current token first, then any
being phased out), INTAKE_FILE (default ./intake.json), INTAKE_PORT (8787).
"""
import datetime
import hashlib
import hmac
import json
import os
import re
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_SKEW = 300  # seconds between the phone's clock and ours
HISTORY_DAYS = 60   # each day's last food total is kept this long (the face's streak)
WATCH_DAYS = 10     # ... and the watch gets the most recent of them (it has 7 days of calories burned)


def read_tokens():
    return [t.strip() for t in os.environ.get("INTAKE_READ_TOKENS", "").split(",") if t.strip()]


def authorised(header, tokens):
    """Constant-time bearer-token check against any of `tokens`. Empty tokens never match."""
    if not header or not header.startswith("Bearer "):
        return False
    given = header[len("Bearer "):].encode()
    return any(hmac.compare_digest(given, t.encode()) for t in tokens if t)


def signature(time_text, kcal_text, secret):
    return hashlib.sha256(("%s|%s|%s" % (time_text, kcal_text, secret)).encode()).hexdigest()


def parse_kcal_text(text):
    """kcal as Shortcuts formats it ("1300", "1,300.5", "1300 kcal") -> int."""
    cleaned = re.sub(r"[^0-9.]", "", text or "")
    try:
        kcal = float(cleaned)
    except ValueError:
        raise ValueError("X-Intake-In must be a number of kcal")
    if not 0 <= kcal <= 20000:
        raise ValueError("X-Intake-In out of range")
    return int(round(kcal))


class Rejected(Exception):
    def __init__(self, status, reason):
        super().__init__(reason)
        self.status = status
        self.reason = reason


def check_push(headers, secret, last_record, now=None):
    """Validate a signed push. `headers` has lower-case keys. Returns the record to store, or None when the push
    is valid but empty (nothing logged yet). Raises Rejected otherwise."""
    now = time.time() if now is None else now
    if not secret:
        raise Rejected(503, "signing secret not configured")
    time_text = headers.get("x-intake-time")
    kcal_text = headers.get("x-intake-in")
    sig = (headers.get("x-intake-signature") or "").strip().lower()
    if time_text is None or kcal_text is None or not sig:
        raise Rejected(401, "missing signature headers")
    if not hmac.compare_digest(sig.encode(), signature(time_text, kcal_text, secret).encode()):
        raise Rejected(401, "bad signature")
    try:
        sent_at = datetime.datetime.fromisoformat(time_text.strip())
    except ValueError:
        raise Rejected(400, "X-Intake-Time must be ISO 8601 with a UTC offset")
    if sent_at.tzinfo is None:
        raise Rejected(400, "X-Intake-Time needs a UTC offset")
    sent = int(sent_at.timestamp())
    if abs(now - sent) > MAX_SKEW:
        raise Rejected(401, "stale or future timestamp")
    if not kcal_text.strip():  # stores nothing, so nothing to replay-protect
        return None
    if last_record and isinstance(last_record.get("sent"), int) and sent <= last_record["sent"]:
        raise Rejected(409, "replayed or out-of-order push")
    try:
        kcal = parse_kcal_text(kcal_text)
    except ValueError as e:
        raise Rejected(400, str(e))
    # The phone's local date: the watch compares it with its own date.
    record = {"date": sent_at.date().isoformat(), "in": kcal, "bmr": None, "ts": int(now), "sent": sent}
    return with_history(record, last_record)


def with_history(record, last_record):
    """The new record plus "days": each day's latest food total, for the last HISTORY_DAYS days. A day
    keeps the total of its last push, so yesterday's entry is final once today's first push arrives."""
    last = last_record or {}
    days = dict(last.get("days") or {})
    if isinstance(last.get("date"), str) and isinstance(last.get("in"), int):
        days[last["date"]] = last["in"]          # also covers a record stored before the history existed
    days[record["date"]] = record["in"]
    return {**record, "days": {d: days[d] for d in sorted(days)[-HISTORY_DAYS:]}}


def for_watch(record):
    """What GET returns: the record with only the last WATCH_DAYS days of history (the watch's payload is small)."""
    days = record.get("days")
    if not isinstance(days, dict):
        return record
    return {**record, "days": {d: days[d] for d in sorted(days)[-WATCH_DAYS:]}}


def write_atomic(path, record):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".intake-")
    with os.fdopen(fd, "w") as f:
        json.dump(record, f)
    os.replace(tmp, path)


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return None


class Handler(BaseHTTPRequestHandler):
    server_version = "buff-intake"

    def _send(self, code, obj=None):
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code)
        if obj is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.partition("?")[0]
        if path == "/healthz":
            return self._send(200, "ok")
        if path != "/intake":
            return self._send(404)
        if not authorised(self.headers.get("Authorization"), read_tokens()):
            return self._send(401)
        record = read_json(self.server.intake_file)
        return self._send(200, for_watch(record)) if record is not None else self._send(404)

    def do_POST(self):
        if self.path.partition("?")[0] != "/intake":
            return self._send(404)
        headers = {k.lower(): v for k, v in self.headers.items()}
        try:
            record = check_push(headers, os.environ.get("INTAKE_SIGNING_SECRET"), read_json(self.server.intake_file))
        except Rejected as e:
            return self._send(e.status, {"error": e.reason})
        if record is None:
            return self._send(200, {"skipped": "nothing logged yet"})
        write_atomic(self.server.intake_file, record)
        return self._send(200, record)

    def log_message(self, fmt, *args):  # one line per request; never headers or query (secrets)
        print("%s %s" % (self.command, self.path.partition("?")[0]), args[1] if len(args) > 1 else "", flush=True)


def make_server(port, intake_file):
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    httpd.intake_file = intake_file
    return httpd


if __name__ == "__main__":
    if not os.environ.get("INTAKE_SIGNING_SECRET") or not read_tokens():
        raise SystemExit("INTAKE_SIGNING_SECRET and INTAKE_READ_TOKENS must be set")
    port = int(os.environ.get("INTAKE_PORT", "8787"))
    make_server(port, os.environ.get("INTAKE_FILE", "intake.json")).serve_forever()
