import Toybox.Lang;
import Toybox.Math;

// The maths behind the face, kept free of device calls so source/test/Tests.mc can check it (`make test`).

// The buddy's levels. Everything is measured as "progress": how far the right arc's reading is towards its goal
// (or along its scale), 0 to 1 and beyond. FLATLINING below 1/6, ACTIVE from 1/6, INTENSE from 2/3, INSANE at the
// goal. In calorie deficit mode the goal is Config.DEFICIT_TARGET_KCAL (1,500), so 250 / 1,000 / 1,500 kcal.
// RESTING (asleep) has no range: it's the pose while there's no reading yet.
module Buff {
    const FLATLINING = 0;
    const RESTING = 1;
    const ACTIVE = 2;
    const INTENSE = 3;
    const INSANE = 4;
    const LABELS = ["FLATLINING", "RESTING", "ACTIVE", "INTENSE", "INSANE"] as Array<String>;

    const ACTIVE_AT = 1.0 / 6;
    const INTENSE_AT = 2.0 / 3;

    function state(progress as Float) as Number {
        if (progress >= 1.0) {
            return INSANE;
        } else if (progress >= INTENSE_AT) {
            return INTENSE;
        } else if (progress >= ACTIVE_AT) {
            return ACTIVE;
        }
        return FLATLINING;
    }

    function clamp(p as Float) as Float {
        return p < 0.0 ? 0.0 : (p > 1.0 ? 1.0 : p);
    }

    // 340, 3.6K, 12K (steps, calories)
    function kilo(n as Number) as String {
        var a = n < 0 ? -n : n;
        var s;
        if (a < 1000) {
            s = a.toString();
        } else if (a < 10000) {
            var tenths = a / 100;
            s = (tenths / 10).toString() + (tenths % 10 == 0 ? "" : "." + (tenths % 10).toString()) + "K";
        } else {
            s = (a / 1000).toString() + "K";
        }
        return n < 0 ? "-" + s : s;
    }
}

// Optional calorie deficit mode (Config, docs/deficit-mode.md): burned (the watch) minus eaten (your server).
module Deficit {
    const KCAL_PER_GRAM = 7.7;      // ~7,700 kcal per kg of body fat: the grams are a fat *equivalent*

    function progress(deficit as Number) as Float {
        return deficit.toFloat() / Config.DEFICIT_TARGET_KCAL;
    }

    // Rounded, never negative (a surplus shows 0 g)
    function grams(deficit as Number) as Number {
        return deficit <= 0 ? 0 : Math.round(deficit / KCAL_PER_GRAM).toNumber();
    }

    // A streak day ends Intense or better. No food logged (eaten null) never counts.
    function hit(burned as Number?, eaten as Number?) as Boolean {
        return burned != null && eaten != null && progress(burned - eaten) >= Buff.INTENSE_AT;
    }
}

// Consecutive streak days: days that ended Intense or better. Days are numbered from 1970-01-01 in the watch's
// local calendar. The streak through the day before yesterday is stored ([last day counted, streak]); yesterday
// stays open (a late food log in deficit mode can still count it) until today ends, and today adds one only once
// it reaches Intense (it isn't over yet).
module Streak {

    // Days since 1970-01-01 for a calendar date (proleptic Gregorian, Howard Hinnant's days_from_civil).
    function dayIndex(y as Number, m as Number, d as Number) as Number {
        var yy = m <= 2 ? y - 1 : y;
        var era = (yy >= 0 ? yy : yy - 399) / 400;
        var yoe = yy - era * 400;
        var doy = (153 * ((m + 9) % 12) + 2) / 5 + d - 1;      // March = month 0
        var doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }

    // "2026-11-08" (a server's date key) -> day index, or null
    function parseKey(key as Object or Null) as Number? {
        if (!(key instanceof String) || key.length() != 10) {
            return null;
        }
        var y = key.substring(0, 4).toNumberWithBase(10);
        var m = key.substring(5, 7).toNumberWithBase(10);
        var d = key.substring(8, 10).toNumberWithBase(10);
        if (y == null || m == null || d == null) {
            return null;
        }
        return dayIndex(y, m, d);
    }

    // Count the days after `last` up to the day before yesterday into the stored streak `n`: a streak day
    // (hits[day] == true) adds one, any other day starts again from 0. Returns the new [last, n].
    function advance(last as Number, n as Number, today as Number, hits as Dictionary<Number, Boolean>)
            as Array<Number> {
        var from = last + 1;
        if (from < today - 30) {   // a long gap: nothing to go on
            from = today - 30;
            n = 0;
        }
        for (var day = from; day <= today - 2; day++) {
            n = hits[day] == true ? n + 1 : 0;
            last = day;
        }
        return [last, n];
    }

    // The streak to show today, from the stored [last, n] (after advance()).
    function shown(last as Number, n as Number, today as Number, hits as Dictionary<Number, Boolean>,
                   todayHit as Boolean) as Number {
        var through;
        if (last >= today - 1) {   // the date went back (flying east over the date line): keep what we had
            through = n;
        } else {
            var before = last == today - 2 ? n : 0;
            through = hits[today - 1] == true ? before + 1 : 0;
        }
        return todayHit ? through + 1 : through;
    }
}
