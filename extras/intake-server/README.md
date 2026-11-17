# Intake server (optional)

A tiny server for Buff's calorie deficit mode (`docs/deficit-mode.md`): your phone tells it what you've eaten today,
and the watch reads it back. Python 3.11+, standard library only.

```sh
export INTAKE_SIGNING_SECRET="$(openssl rand -hex 32)"   # shared with your phone
export INTAKE_READ_TOKENS="$(openssl rand -hex 32)"      # goes in the face's source/Secrets.mc
python3 intake_server.py                                 # http://127.0.0.1:8787/intake (INTAKE_PORT to change)
```

Put it behind HTTPS (for example Caddy or nginx with Let's Encrypt, or a serverless function wrapping `check_push`
and `for_watch`): the watch only talks to `https://` URLs.

## The phone's push

`POST /intake` with no body and three headers:

| Header | Value |
|---|---|
| `X-Intake-Time` | the phone's local time, ISO 8601 with its UTC offset, e.g. `2026-11-17T16:20:31-05:00` |
| `X-Intake-In` | kcal eaten today, e.g. `1450` |
| `X-Intake-Signature` | `sha256_hex(time + "|" + in + "|" + INTAKE_SIGNING_SECRET)` |

The secret itself is never sent. A push is rejected if its time is more than 5 minutes off, or not newer than the
last one, so a captured request can't be replayed. On an iPhone, a Shortcuts automation can do this: find today's
Dietary Energy samples in Health, sum them, then build the time, signature and request with Shortcuts' own actions.

## The watch's read

`GET /intake` with `Authorization: Bearer <one of INTAKE_READ_TOKENS>` returns the face's JSON (see
`docs/deficit-mode.md`). To rotate the token, list the new one first and the old one after it, then drop the old one
once the watch has the new one.

Tests: `python3 -m unittest test_intake_server` (from this folder).
