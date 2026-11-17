import Toybox.ActivityMonitor;
import Toybox.Complications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.UserProfile;
import Toybox.WatchUi;

// One arc's reading, ready to draw: the number and label under the buddy's arm, how full the arc is, and how far
// along the buddy would be if this were the right arc.
class Reading {
    var metric as Number = Metrics.STEPS;
    var known as Boolean = false;
    var value as String = "—";
    var label as String = "";
    var frac as Float = 0.0;        // the arc, 0..1
    var good as Float = 0.0;        // the buddy's progress, 0..1+ (lower-is-better readings are flipped)

    function initialize() {
    }
}

// What each arc can track. Wearers pick one per arc in the watch's own editor (Customize > Data), which only offers
// Garmin's complication types (resources/configs/watchface.xml), so each choice maps from one of those. Garmin
// doesn't offer active calories, resting heart rate or HRV in that list (and doesn't give watch faces HRV at all):
// "Calories" shows active calories (Config.CALORIES_TOTAL for the total) and "Heart rate" shows resting heart rate.
module Metrics {
    const STEPS = 0;
    const CALORIES = 1;
    const INTENSITY = 2;        // intensity minutes today
    const FLOORS = 3;
    const BODY_BATTERY = 4;
    const STRESS = 5;
    const SLEEP = 6;            // sleep score
    const RESTING_HR = 7;
    const RECOVERY = 8;         // recovery time, hours
    const PULSE_OX = 9;
    const BATTERY = 10;         // the watch's own battery
    const DEFICIT = 11;         // optional calorie deficit mode (Config); never picked in Customize

    const LABELS = ["STEPS LEFT", "ACTIVE KCAL", "INTENSITY MIN", "FLOORS", "BODY BATTERY", "STRESS", "SLEEP SCORE",
                    "RESTING HR", "RECOVERY HRS", "PULSE OX", "BATTERY", "KCAL DEFICIT"] as Array<String>;

    // Customize's choice for an arc -> metric (null for anything Buff can't show)
    function fromType(t as Complications.Type?) as Number? {
        switch (t) {
            case Complications.COMPLICATION_TYPE_STEPS: return STEPS;
            case Complications.COMPLICATION_TYPE_CALORIES: return CALORIES;
            case Complications.COMPLICATION_TYPE_INTENSITY_MINUTES: return INTENSITY;
            case Complications.COMPLICATION_TYPE_FLOORS_CLIMBED: return FLOORS;
            case Complications.COMPLICATION_TYPE_BODY_BATTERY: return BODY_BATTERY;
            case Complications.COMPLICATION_TYPE_STRESS: return STRESS;
            case Complications.COMPLICATION_TYPE_SLEEP_SCORE: return SLEEP;
            case Complications.COMPLICATION_TYPE_HEART_RATE: return RESTING_HR;
            case Complications.COMPLICATION_TYPE_RECOVERY_TIME: return RECOVERY;
            case Complications.COMPLICATION_TYPE_PULSE_OX: return PULSE_OX;
            case Complications.COMPLICATION_TYPE_BATTERY: return BATTERY;
        }
        return null;
    }

    function icon(m as Number) as ResourceId {
        return [Rez.Drawables.IconFootprints, Rez.Drawables.IconFlame, Rez.Drawables.IconZap,
                Rez.Drawables.IconChevronsUp, Rez.Drawables.IconBatteryCharging, Rez.Drawables.IconActivity,
                Rez.Drawables.IconMoon, Rez.Drawables.IconHeart, Rez.Drawables.IconHourglass,
                Rez.Drawables.IconDroplet, Rez.Drawables.IconBatteryMedium, Rez.Drawables.IconFlame][m];
    }

    // Readings with a daily goal (and a daily history, so they can keep a streak)
    function hasGoal(m as Number) as Boolean {
        return m == STEPS || m == CALORIES || m == INTENSITY || m == FLOORS;
    }

    // [low, high, lower is better] for readings without a goal
    function scale(m as Number) as Array {
        switch (m) {
            case RESTING_HR: return [Config.RESTING_HR_SCALE[0], Config.RESTING_HR_SCALE[1], true];
            case RECOVERY: return [Config.RECOVERY_SCALE[0], Config.RECOVERY_SCALE[1], true];
            case PULSE_OX: return [Config.PULSE_OX_SCALE[0], Config.PULSE_OX_SCALE[1], false];
            case STRESS: return [0, 100, true];
        }
        return [0, 100, false];     // body battery, sleep score, battery
    }

    // The reading for metric m from its raw value (null: no reading) and, for goal metrics, the day's goal.
    function reading(m as Number, raw as Number?, goal as Number?) as Reading {
        var r = new Reading();
        r.metric = m;
        r.label = LABELS[m];
        if (m == CALORIES && Config.CALORIES_TOTAL) {
            r.label = "KCAL";
        }
        if (raw == null || (hasGoal(m) && (goal == null || goal <= 0))) {
            return r;
        }
        r.known = true;
        if (hasGoal(m)) {
            r.good = raw.toFloat() / (goal as Number);
            r.frac = Buff.clamp(r.good);
            if (m == STEPS) {   // a countdown to the step goal, then how far past it
                if (raw < goal) {
                    r.value = Buff.kilo((goal as Number) - raw);
                } else {
                    r.value = "+" + Buff.kilo(raw - (goal as Number));
                    r.label = "OVER GOAL";
                }
            } else {
                r.value = m == CALORIES ? Buff.kilo(raw) : raw.toString();
            }
        } else {
            var s = scale(m);
            var lo = s[0] as Number;
            var hi = s[1] as Number;
            r.frac = Buff.clamp((raw - lo).toFloat() / (hi - lo));
            r.good = s[2] == true ? 1.0 - r.frac : r.frac;
            r.value = raw.toString() + (m == BATTERY || m == PULSE_OX ? "%" : "");
        }
        return r;
    }

    // The deficit side in calorie deficit mode (eaten null: no food logged yet today)
    function deficitReading(burned as Number?, eaten as Number?) as Reading {
        var r = new Reading();
        r.metric = DEFICIT;
        r.label = LABELS[DEFICIT];
        if (burned == null || eaten == null) {
            return r;
        }
        var d = burned - eaten;
        r.known = true;
        r.good = Deficit.progress(d);
        r.frac = Buff.clamp(r.good);
        if (d >= 0) {
            r.value = Buff.kilo(d);
        } else {
            r.value = "+" + Buff.kilo(-d);
            r.label = "KCAL SURPLUS";
        }
        return r;
    }

    // ---- Calories ------------------------------------------------------------------------------------------------

    // Resting calories a day (Mifflin-St Jeor) from a Garmin profile: weight g, height cm, age, sex. Null if the
    // profile is incomplete.
    function bmr(weightG as Number?, heightCm as Number?, age as Number?, male as Boolean) as Number? {
        if (weightG == null || heightCm == null || age == null || weightG <= 0 || heightCm <= 0) {
            return null;
        }
        return (10.0 * weightG / 1000 + 6.25 * heightCm - 5 * age + (male ? 5 : -161)).toNumber();
    }

    // Calories burned above the resting rate so far today
    function activeKcal(total as Number, bmrDay as Number, minuteOfDay as Number) as Number {
        var a = total - bmrDay * minuteOfDay / 1440;
        return a < 0 ? 0 : a;
    }

    // ---- Live values (the watch) ---------------------------------------------------------------------------------

    function profileBmr() as Number? {
        var p = UserProfile.getProfile();
        var year = p.birthYear;
        var age = year != null ? Gregorian.info(Time.now(), Time.FORMAT_SHORT).year - year : null;
        return bmr(p.weight, p.height, age, p.gender == UserProfile.GENDER_MALE);
    }

    // Today's reading for metric m
    function live(m as Number, info as ActivityMonitor.Info, minuteOfDay as Number) as Reading {
        var raw = null;
        var goal = null;
        switch (m) {
            case STEPS:
                raw = info.steps;
                goal = info.stepGoal;
                break;
            case CALORIES:
                raw = info.calories;
                if (Config.CALORIES_TOTAL) {
                    goal = Config.TOTAL_KCAL_GOAL;
                } else {
                    var b = profileBmr();
                    raw = raw != null && b != null ? activeKcal(raw, b, minuteOfDay) : null;
                    goal = Config.ACTIVE_KCAL_GOAL;
                }
                break;
            case INTENSITY:
                var day = info.activeMinutesDay;
                raw = day != null ? day.total : null;
                goal = dailyIntensityGoal(info);
                break;
            case FLOORS:
                raw = info.floorsClimbed;
                goal = info.floorsClimbedGoal;
                break;
            case STRESS:
                raw = info has :stressScore ? info.stressScore : null;
                if (raw == null || raw < 0) {
                    raw = complication(Complications.COMPLICATION_TYPE_STRESS);
                }
                break;
            case RESTING_HR:
                var p = UserProfile.getProfile();
                raw = p.averageRestingHeartRate != null ? p.averageRestingHeartRate : p.restingHeartRate;
                break;
            case RECOVERY:
                raw = info has :timeToRecovery ? info.timeToRecovery : null;
                break;
            case BODY_BATTERY:
                raw = complication(Complications.COMPLICATION_TYPE_BODY_BATTERY);
                break;
            case SLEEP:
                raw = complication(Complications.COMPLICATION_TYPE_SLEEP_SCORE);
                break;
            case PULSE_OX:
                raw = complication(Complications.COMPLICATION_TYPE_PULSE_OX);
                break;
            case BATTERY:
                raw = System.getSystemStats().battery.toNumber();
                break;
        }
        if (raw != null && raw < 0) {   // Garmin's "not available" readings (stress during an activity)
            raw = null;
        }
        return reading(m, raw as Number?, goal as Number?);
    }

    // Garmin's intensity goal is weekly: a day's share of it
    function dailyIntensityGoal(info as ActivityMonitor.Info) as Number? {
        var week = info.activeMinutesWeekGoal;
        return week != null && week > 0 ? (week + 6) / 7 : null;
    }

    // A complication's current value as a whole number, or null
    function complication(type as Complications.Type) as Number? {
        try {
            var v = Complications.getComplication(new Complications.Id(type)).value;
            if (v instanceof Number) {
                return v;
            } else if (v instanceof Float || v instanceof Double || v instanceof Long) {
                return v.toNumber();
            } else if (v instanceof String) {
                return v.toNumber();
            }
        } catch (e) {
        }
        return null;
    }

    // How far a past day got towards its goal (ActivityMonitor history), for the streak; null if unknown
    function dayProgress(m as Number, h as ActivityMonitor.History, weekGoal as Number?, bmrDay as Number?)
            as Float? {
        switch (m) {
            case STEPS:
                return h.steps != null && h.stepGoal != null && h.stepGoal > 0 ? h.steps.toFloat() / h.stepGoal : null;
            case CALORIES:
                if (h.calories == null) {
                    return null;
                } else if (Config.CALORIES_TOTAL) {
                    return h.calories.toFloat() / Config.TOTAL_KCAL_GOAL;
                }
                return bmrDay != null ? activeKcal(h.calories, bmrDay, 1440).toFloat() / Config.ACTIVE_KCAL_GOAL : null;
            case INTENSITY:
                var a = h.activeMinutes;
                return a != null && weekGoal != null && weekGoal > 0 ? a.total.toFloat() / ((weekGoal + 6) / 7) : null;
            case FLOORS:
                return h.floorsClimbed != null && h.floorsClimbedGoal != null && h.floorsClimbedGoal > 0
                    ? h.floorsClimbed.toFloat() / h.floorsClimbedGoal : null;
        }
        return null;
    }
}
