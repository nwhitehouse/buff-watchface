"""Tests for intake_server.py:  python3 -m unittest discover -s server"""
import datetime
import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

import intake_server as srv

SECRET = "s" * 64
NZ = datetime.timezone(datetime.timedelta(hours=13))


def signed(kcal_text, when=None, secret=SECRET):
    when = when or datetime.datetime.now(NZ).replace(microsecond=0)
    t = when.isoformat()
    return {"x-intake-time": t, "x-intake-in": kcal_text, "x-intake-signature": srv.signature(t, kcal_text, secret)}


class CheckPush(unittest.TestCase):
    def test_valid_push_uses_phone_date(self):
        when = datetime.datetime(2026, 11, 7, 23, 50, tzinfo=NZ)  # 10:50 UTC: the NZ date must win
        r = srv.check_push(signed("1,300.6 kcal", when), SECRET, None, now=when.timestamp())
        self.assertEqual((r["date"], r["in"], r["sent"]), ("2026-11-07", 1301, int(when.timestamp())))

    def test_history_keeps_each_days_last_total(self):
        """"days" holds each day's latest total, also for a record stored before the history existed."""
        day1 = datetime.datetime(2026, 11, 7, 21, 0, tzinfo=NZ)
        r1 = {"date": "2026-11-07", "in": 1500, "bmr": None, "ts": 1, "sent": 1}    # old format, no "days"
        r2 = srv.check_push(signed("1,650", day1), SECRET, r1, now=day1.timestamp())
        self.assertEqual(r2["days"], {"2026-11-07": 1650})
        day2 = datetime.datetime(2026, 11, 8, 8, 0, tzinfo=NZ)
        r3 = srv.check_push(signed("300", day2), SECRET, r2, now=day2.timestamp())
        self.assertEqual(r3["days"], {"2026-11-07": 1650, "2026-11-08": 300})
        self.assertEqual((r3["date"], r3["in"]), ("2026-11-08", 300))

    def test_history_is_trimmed(self):
        last = {"date": "2026-01-01", "in": 1, "sent": 0,
                "days": {(datetime.date(2026, 1, 1) + datetime.timedelta(d)).isoformat(): d for d in range(70)}}
        when = datetime.datetime(2026, 11, 8, 8, 0, tzinfo=NZ)
        r = srv.check_push(signed("300", when), SECRET, last, now=when.timestamp())
        self.assertEqual(len(r["days"]), srv.HISTORY_DAYS)
        self.assertEqual(max(r["days"]), "2026-11-08")
        w = srv.for_watch(r)
        self.assertEqual(sorted(w["days"]), sorted(r["days"])[-srv.WATCH_DAYS:])
        self.assertEqual(len(r["days"]), srv.HISTORY_DAYS)          # for_watch doesn't change the stored record

    def test_uppercase_signature_ok(self):
        h = signed("500")
        h["x-intake-signature"] = h["x-intake-signature"].upper()
        self.assertEqual(srv.check_push(h, SECRET, None)["in"], 500)

    def test_empty_is_skipped(self):
        self.assertIsNone(srv.check_push(signed(""), SECRET, None))

    def rejected(self, headers, status, last=None, now=None, secret=SECRET):
        with self.assertRaises(srv.Rejected) as cm:
            srv.check_push(headers, secret, last, now=now)
        self.assertEqual(cm.exception.status, status, cm.exception.reason)

    def test_bad_signature(self):
        h = signed("500")
        h["x-intake-in"] = "50"  # tampered value
        self.rejected(h, 401)
        self.rejected(signed("500", secret="wrong"), 401)
        self.rejected({"x-intake-time": "x", "x-intake-in": "1"}, 401)  # missing signature
        self.rejected(signed("500"), 503, secret="")                # server not configured

    def test_stale_and_future(self):
        old = datetime.datetime.now(NZ) - datetime.timedelta(minutes=6)
        self.rejected(signed("500", old), 401)
        future = datetime.datetime.now(NZ) + datetime.timedelta(minutes=6)
        self.rejected(signed("500", future), 401)

    def test_replay_blocked(self):
        h = signed("500")
        first = srv.check_push(h, SECRET, None)
        self.rejected(h, 409, last=first)  # same request again

    def test_bad_time_and_value(self):
        t = "2026-11-07 16:20"  # no offset
        self.rejected({"x-intake-time": t, "x-intake-in": "1", "x-intake-signature": srv.signature(t, "1", SECRET)}, 400)
        self.rejected(signed("abc"), 400)
        self.rejected(signed("99999"), 400)


class Auth(unittest.TestCase):
    def test_bearer_any_of_tokens(self):
        self.assertTrue(srv.authorised("Bearer new", ["new", "old"]))
        self.assertTrue(srv.authorised("Bearer old", ["new", "old"]))
        self.assertFalse(srv.authorised("Bearer other", ["new", "old"]))
        self.assertFalse(srv.authorised("new", ["new"]))
        self.assertFalse(srv.authorised(None, ["new"]))
        self.assertFalse(srv.authorised("Bearer ", []))


class Http(unittest.TestCase):
    def setUp(self):
        os.environ["INTAKE_SIGNING_SECRET"] = SECRET
        os.environ["INTAKE_READ_TOKENS"] = "r-new,r-old"
        self.tmp = tempfile.TemporaryDirectory()
        self.httpd = srv.make_server(0, os.path.join(self.tmp.name, "intake.json"))
        self.base = "http://127.0.0.1:%d/intake" % self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.tmp.cleanup()

    def call(self, method, headers, url=None):
        req = urllib.request.Request(url or self.base, method=method, headers=headers,
                                     data=b"" if method == "POST" else None)
        try:
            with urllib.request.urlopen(req) as r:
                return r.status, json.loads(r.read() or b"null")
        except urllib.error.HTTPError as e:
            e.close()
            return e.code, None

    def test_round_trip(self):
        self.assertEqual(self.call("GET", {"Authorization": "Bearer r-new"})[0], 404)
        code, rec = self.call("POST", {k.title(): v for k, v in signed("1300").items()})
        self.assertEqual(code, 200)
        self.assertEqual(self.call("GET", {"Authorization": "Bearer r-old"}), (200, rec))

    def test_no_tokens_in_url(self):
        self.assertEqual(self.call("GET", {}, self.base + "?token=r-new")[0], 401)


if __name__ == "__main__":
    unittest.main()
