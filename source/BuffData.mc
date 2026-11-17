import Toybox.ActivityMonitor;
import Toybox.Application;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;

// What each arc tracks, as chosen in Customize > Data (BuffView.applyConfig). The buddy follows the right arc.
module Slots {
    const LEFT_ID = 1;          // complication ids in resources/configs/watchface.xml
    const RIGHT_ID = 2;
    var left as Number = Metrics.STEPS;
    var right as Number = Metrics.CALORIES;

    // The editor: a tap on the left or right half picks that arc's slot
    function at(x as Number, y as Number) as Number? {
        return x < Layout.CX ? LEFT_ID : RIGHT_ID;
    }

    // [x, y, w, h] around a side's number, label and arc icon (0 left, 1 right)
    function box(side as Number) as Array<Number> {
        var x = side == 0 ? BuffGen.STAT_CX_L - 62 : BuffGen.STAT_CX_R - 62;
        return [x, BuffGen.STAT_NUM_BASE - 40, 124, BuffGen.ICON_LEFT[1] + BuffGen.ICON_PX + 6 - (BuffGen.STAT_NUM_BASE - 40)];
    }
}

// Everything the face shows, refreshed once a minute (and when Customize or the optional intake push changes it).
// `make mockup` builds the (:mockup) update() instead, with the values in Mock below.
class BuffData {
    var hour as Number = 0;                     // 0-23, or 1-12 on a 12-hour watch
    var minute as Number = 0;
    var dateText as String = "";                // THU 5 NOV

    var left as Reading = new Reading();        // the left arc and the number under the buddy's left arm
    var right as Reading = new Reading();       // the right arc; the buddy follows it
    var known as Boolean = false;               // the right arc has a reading
    var state as Number = Buff.RESTING;         // the buddy's pose (Buff.FLATLINING..INSANE)
    var progress as Float = 0.0;                // the buddy's fill, 0..1
    var label as String = "";                   // ACTIVE, INTENSE, ... or NO DATA
    var centre as String = "—";                 // the big number: % of the right arc's goal, or grams in deficit mode
    var unit as String = "%";
    var streak as Number = 0;                   // days ending Intense or better in a row, today once it's there

    // Calorie deficit mode (Config): on when this build has a server to ask (source/Secrets.mc)
    var deficitMode as Boolean = Secrets.INTAKE_URL.length() > 0;

    private var _history as Dictionary<Number, ActivityMonitor.History> = {} as Dictionary<Number, ActivityMonitor.History>;
    private var _historyDay as Number = -1;     // day the history was read on (past days don't change)
    private var _eaten as Dictionary<Number, Number> = {} as Dictionary<Number, Number>;   // deficit mode: day -> kcal
    private var _intakeRead as Boolean = false;
    private var _streak as Array<Number>? = null;   // stored [last day counted, streak] for _streakKey
    private var _streakKey as String = "";

    function initialize() {
    }

    (:live)
    function update() as Void {
        var clock = System.getClockTime();
        hour = clock.hour;
        minute = clock.min;
        if (!System.getDeviceSettings().is24Hour) {
            hour = hour % 12 == 0 ? 12 : hour % 12;
        }
        var now = Time.now();
        var d = Gregorian.info(now, Time.FORMAT_MEDIUM);
        dateText = (d.day_of_week as String).toUpper() + " " + d.day + " " + (d.month as String).toUpper();
        var s = Gregorian.info(now, Time.FORMAT_SHORT);
        var today = Streak.dayIndex(s.year, s.month as Number, s.day);
        var minuteOfDay = clock.hour * 60 + clock.min;

        var info = ActivityMonitor.getInfo();
        if (_historyDay != today) {
            _history = historyByDay();
            _historyDay = today;
        }
        left = Metrics.live(Slots.left, info, minuteOfDay);
        var hits = {} as Dictionary<Number, Boolean>;
        var todayHit = false;
        var deficit = null;
        if (deficitMode) {
            if (!_intakeRead) {
                _eaten = eatenByDay(Application.Storage.getValue("intake"));
                _intakeRead = true;
            }
            right = Metrics.deficitReading(info.calories, _eaten[today]);
            deficit = right.known ? (info.calories as Number) - (_eaten[today] as Number) : null;
            var days = _history.keys();
            for (var i = 0; i < days.size(); i++) {
                hits[days[i]] = Deficit.hit(_history[days[i]].calories, _eaten[days[i]]);
            }
            todayHit = Deficit.hit(info.calories, _eaten[today]);
        } else {
            right = Metrics.live(Slots.right, info, minuteOfDay);
            if (Metrics.hasGoal(Slots.right)) {
                var weekGoal = info.activeMinutesWeekGoal;
                var bmr = Slots.right == Metrics.CALORIES ? Metrics.profileBmr() : null;
                var days = _history.keys();
                for (var i = 0; i < days.size(); i++) {
                    var p = Metrics.dayProgress(Slots.right, _history[days[i]], weekGoal, bmr);
                    hits[days[i]] = p != null && p >= Buff.INTENSE_AT;
                }
                todayHit = right.known && right.good >= Buff.INTENSE_AT;
            }
        }
        setBuddy(deficit);
        // A streak needs a daily goal with a history (steps, calories, intensity minutes, floors) or deficit mode
        var keeps = deficitMode || Metrics.hasGoal(Slots.right);
        streak = keeps ? updateStreak(today, hits, todayHit, deficitMode ? "deficit" : Slots.right.toString()) : 0;
    }

    // The buddy, his label and the big number, from the right arc's reading
    private function setBuddy(deficit as Number?) as Void {
        known = right.known;
        if (known) {
            progress = Buff.clamp(right.good);
            state = Buff.state(right.good);
            label = Buff.LABELS[state];
            if (deficit != null) {
                centre = Deficit.grams(deficit).toString();
                unit = "g";
            } else {
                var pct = Math.round(right.good * 100).toNumber();
                centre = (pct < 0 ? 0 : (pct > 999 ? 999 : pct)).toString();
                unit = "%";
            }
        } else {   // nothing to go on yet: asleep, waiting
            state = Buff.RESTING;
            progress = 0.0;
            label = deficitMode ? "NO FOOD LOGGED" : "NO DATA";
            centre = "—";
            unit = deficitMode ? "g" : "%";
        }
    }

    // Design check: the values in Mock below, at 14:32 on THU 5 NOV.
    (:mockup)
    function update() as Void {
        hour = 14;
        minute = 32;
        dateText = "THU 5 NOV";
        deficitMode = Mock.DEFICIT_MODE;
        left = Metrics.reading(Slots.left, Mock.LEFT_RAW < 0 ? null : Mock.LEFT_RAW, Mock.LEFT_GOAL);
        var deficit = null;
        if (deficitMode) {
            right = Mock.DEFICIT < -9000 ? Metrics.deficitReading(2000, null) : Metrics.deficitReading(2000 + Mock.DEFICIT, 2000);
            deficit = right.known ? Mock.DEFICIT : null;
        } else {
            right = Metrics.reading(Slots.right, Mock.RIGHT_RAW < 0 ? null : Mock.RIGHT_RAW, Mock.RIGHT_GOAL);
        }
        setBuddy(deficit);
        streak = Mock.STREAK;
    }

    // Customize changed, or a new intake push arrived (BuffApp): re-read on the next update.
    function settingsChanged() as Void {
        _intakeRead = false;
    }

    // The watch's own daily history (the last 7 days): day -> History
    (:live)
    private function historyByDay() as Dictionary<Number, ActivityMonitor.History> {
        var out = {} as Dictionary<Number, ActivityMonitor.History>;
        var history = ActivityMonitor.getHistory();
        for (var i = 0; i < history.size(); i++) {
            var h = history[i];
            var start = h.startOfDay;
            if (start != null) {
                // Midday of that day, so the date is right whether startOfDay is local or UTC midnight
                var t = Gregorian.info(start.add(new Time.Duration(12 * 3600)), Time.FORMAT_SHORT);
                out[Streak.dayIndex(t.year, t.month as Number, t.day)] = h;
            }
        }
        return out;
    }

    // Deficit mode: food eaten per day from the stored push: today's total ("date" / "in") and recent days ("days")
    (:live)
    private function eatenByDay(intake as Object or Null) as Dictionary<Number, Number> {
        var out = {} as Dictionary<Number, Number>;
        if (!(intake instanceof Dictionary)) {
            return out;
        }
        var days = intake["days"];
        if (days instanceof Dictionary) {
            var keys = days.keys();
            for (var i = 0; i < keys.size(); i++) {
                put(out, Streak.parseKey(keys[i]), days[keys[i]]);
            }
        }
        put(out, Streak.parseKey(intake["date"]), intake["in"]);   // the latest total wins
        return out;
    }

    (:live)
    private function put(out as Dictionary<Number, Number>, day as Number?, kcal as Object or Null) as Void {
        if (day != null && (kcal instanceof Number || kcal instanceof Float)) {
            out[day] = kcal.toNumber();
        }
    }

    // The running streak is stored per right-arc choice, so switching metrics in Customize doesn't mix them up
    (:live)
    private function updateStreak(today as Number, hits as Dictionary<Number, Boolean>, todayHit as Boolean,
                                  key as String) as Number {
        if (_streak == null || !key.equals(_streakKey)) {
            var stored = Application.Storage.getValue("streak_" + key);
            _streak = stored instanceof Array && stored.size() == 2 ? stored as Array<Number> : [today - 9, 0];
            _streakKey = key;
        }
        var st = _streak as Array<Number>;
        var next = Streak.advance(st[0], st[1], today, hits);
        if (next[0] != st[0] || next[1] != st[1]) {
            _streak = next;
            Application.Storage.setValue("streak_" + key, next);
        }
        return Streak.shown(next[0], next[1], today, hits, todayHit);
    }
}

// `make mockup` values. The arcs use Slots' defaults (or set Slots.left / Slots.right in BuffView.readConfig).
(:mockup)
module Mock {
    const LEFT_RAW = 6400;      // steps (-1: no reading)
    const LEFT_GOAL = 10000;
    const RIGHT_RAW = 340;      // active kcal (-1: no reading)
    const RIGHT_GOAL = 500;
    const DEFICIT_MODE = false; // true: the right side shows DEFICIT kcal instead (< -9000: no food logged)
    const DEFICIT = 423;
    const STREAK = 5;
    const THEME = 1;            // 0 White, 1 Cream, 2 Ice, 3 Ember, 4 Coral, 5 Mint
    const LEFT = 0;             // Metrics ids: 0 steps, 1 calories, 2 intensity, 3 floors, 4 body battery, 5 stress,
    const RIGHT = 1;            // 6 sleep, 7 resting HR, 8 recovery, 9 pulse ox, 10 battery
}
