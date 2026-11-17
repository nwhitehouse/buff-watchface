# Optional: calorie deficit mode

Out of the box, Buff only uses your watch. The **calorie deficit mode** is how the face was first built: the right arc,
the buddy and the big number follow your **calorie deficit** for the day (calories burned, from the watch, minus
calories eaten, from your food log), and the big number shows it as grams of fat (deficit ÷ 7.7).

Your watch doesn't know what you ate, so this mode needs **a small server of your own** that the watch can ask.
That's why it's off by default.

## How it fits together

```
your food log ──► your phone ──► your server ◄── the watch (every 15 min, through the Garmin Connect app)
```

1. Something on your phone sends today's food total to your server whenever it changes. (The original setup:
   MyFitnessPal writes to Apple Health, and an iOS Shortcut automation, run when MyFitnessPal closes, reads today's
   dietary energy from Health and posts it, signed with a shared secret.)
2. The server keeps the latest total for each day.
3. The watch fetches it in the background every 15 minutes and works out the deficit itself.

## What the watch expects

`GET <your URL>` with the header `Authorization: Bearer <your read token>`, answering `200` with JSON:

```json
{"date": "2026-11-17", "in": 1450, "days": {"2026-11-16": 2010, "2026-11-17": 1450}}
```

- `date`: today, in your phone's local time (YYYY-MM-DD).
- `in`: kcal eaten so far today.
- `days` (optional): the final total for recent days, for the streak. The watch reads the last 10.

Answer `404` if you have nothing stored yet. Any other failure is ignored, and the watch keeps the last good value.

`extras/intake-server/` is a ready-made server for this, in plain Python with no dependencies. It also handles the
phone's signed push (see its README). Run it anywhere that has HTTPS: the watch only talks to `https://` URLs.

## Turn it on

1. Put your server's URL and read token in `source/Secrets.mc`.
2. Build and install (`make sideload`, or see the README).

Keep that token out of public repos: anyone with it can read your food log. Either keep your fork private, or run
`git update-index --skip-worktree source/Secrets.mc` so git ignores your local edit.

## How it reads

- **Levels:** Flatlining under 250 kcal, Active from 250, Intense from 1,000, Insane at the target. The target is
  1,500 kcal (about 195 g) by default; change it with `DEFICIT_TARGET_KCAL` in `source/Config.mc`.
- **No food logged yet today:** the buddy sleeps, with "NO FOOD LOGGED".
- **Streak:** a day counts when it ends Intense or better, and a day with no food logged breaks it.
- **Travel:** after flying west across the date line, that calendar day runs about 37 hours on the watch. The
  watch counts calories burned from midnight where you left, but your food log counts from midnight where you
  landed. The deficit reads far too high until local midnight, then fixes itself.
