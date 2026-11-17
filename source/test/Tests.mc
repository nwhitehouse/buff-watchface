import Toybox.Lang;
import Toybox.Test;

// Unit tests for Buff.mc and Metrics.mc. Run with `make test` (needs the simulator open: `make sim`).

// ---- levels ------------------------------------------------------------------------------------------------------

(:test)
function levelsFollowProgress(logger as Test.Logger) as Boolean {
    Test.assertEqual(Buff.state(-0.5), Buff.FLATLINING);
    Test.assertEqual(Buff.state(0.16), Buff.FLATLINING);
    Test.assertEqual(Buff.state(0.17), Buff.ACTIVE);
    Test.assertEqual(Buff.state(0.66), Buff.ACTIVE);
    Test.assertEqual(Buff.state(0.67), Buff.INTENSE);
    Test.assertEqual(Buff.state(0.99), Buff.INTENSE);
    Test.assertEqual(Buff.state(1.0), Buff.INSANE);
    Test.assertEqual(Buff.state(2.5), Buff.INSANE);
    return true;
}

(:test)
function deficitLevelsAre250And1000And1500(logger as Test.Logger) as Boolean {
    // With the default 1,500 kcal target
    Test.assertEqual(Buff.state(Deficit.progress(249)), Buff.FLATLINING);
    Test.assertEqual(Buff.state(Deficit.progress(250)), Buff.ACTIVE);
    Test.assertEqual(Buff.state(Deficit.progress(999)), Buff.ACTIVE);
    Test.assertEqual(Buff.state(Deficit.progress(1000)), Buff.INTENSE);
    Test.assertEqual(Buff.state(Deficit.progress(1499)), Buff.INTENSE);
    Test.assertEqual(Buff.state(Deficit.progress(1500)), Buff.INSANE);
    Test.assertEqual(Deficit.grams(423), 55);
    Test.assertEqual(Deficit.grams(1600), 208);
    Test.assertEqual(Deficit.grams(-500), 0);           // a surplus is 0 g, not negative
    Test.assert(Deficit.hit(2500, 1500));               // exactly 1,000: Intense
    Test.assert(!Deficit.hit(2499, 1500));
    Test.assert(!Deficit.hit(3000, null));              // no food logged never counts
    return true;
}

(:test)
function kiloFormatting(logger as Test.Logger) as Boolean {
    Test.assertEqual(Buff.kilo(423), "423");
    Test.assertEqual(Buff.kilo(1000), "1K");
    Test.assertEqual(Buff.kilo(3640), "3.6K");
    Test.assertEqual(Buff.kilo(12345), "12K");
    Test.assertEqual(Buff.kilo(-1540), "-1.5K");
    return true;
}

// ---- readings ----------------------------------------------------------------------------------------------------

(:test)
function stepsCountDownToTheGoal(logger as Test.Logger) as Boolean {
    var r = Metrics.reading(Metrics.STEPS, 6400, 10000);
    Test.assert(r.known);
    Test.assertEqual(r.value, "3.6K");
    Test.assertEqual(r.label, "STEPS LEFT");
    Test.assert(r.frac > 0.639 && r.frac < 0.641);
    r = Metrics.reading(Metrics.STEPS, 11200, 10000);
    Test.assertEqual(r.value, "+1.2K");
    Test.assertEqual(r.label, "OVER GOAL");
    Test.assert(r.frac == 1.0 && r.good > 1.1);         // the arc stops full; the buddy is Insane
    Test.assert(!Metrics.reading(Metrics.STEPS, 500, null).known);   // no goal: nothing to measure against
    Test.assert(!Metrics.reading(Metrics.STEPS, null, 10000).known);
    return true;
}

(:test)
function scalesAndLowerIsBetter(logger as Test.Logger) as Boolean {
    var stress = Metrics.reading(Metrics.STRESS, 25, null);
    Test.assert(stress.frac > 0.249 && stress.frac < 0.251);   // the arc shows the stress
    Test.assert(stress.good > 0.749 && stress.good < 0.751);   // the buddy likes it low
    Test.assertEqual(Buff.state(stress.good), Buff.INTENSE);
    var ox = Metrics.reading(Metrics.PULSE_OX, 95, null);      // 80..100
    Test.assertEqual(ox.value, "95%");
    Test.assert(ox.frac > 0.749 && ox.frac < 0.751);
    var rhr = Metrics.reading(Metrics.RESTING_HR, 120, null);  // off the scale
    Test.assert(rhr.frac == 1.0 && rhr.good == 0.0);
    var bb = Metrics.reading(Metrics.BODY_BATTERY, 100, null);
    Test.assertEqual(Buff.state(bb.good), Buff.INSANE);
    return true;
}

(:test)
function activeCaloriesFromTheProfile(logger as Test.Logger) as Boolean {
    // Mifflin-St Jeor: 10 x 80 kg + 6.25 x 180 cm - 5 x 40 + 5 = 1730
    Test.assertEqual(Metrics.bmr(80000, 180, 40, true), 1730);
    Test.assertEqual(Metrics.bmr(80000, 180, 40, false), 1564);
    Test.assert(Metrics.bmr(null, 180, 40, true) == null);
    // At midday, half the day's resting calories have gone: 2,000 total - 865 resting = 1,135 active
    Test.assertEqual(Metrics.activeKcal(2000, 1730, 720), 1135);
    Test.assertEqual(Metrics.activeKcal(500, 1730, 720), 0);   // never negative
    var r = Metrics.reading(Metrics.CALORIES, 340, 500);
    Test.assertEqual(r.value, "340");
    Test.assertEqual(r.label, "ACTIVE KCAL");
    return true;
}

(:test)
function deficitReading(logger as Test.Logger) as Boolean {
    var r = Metrics.deficitReading(2900, 2000);
    Test.assertEqual(r.value, "900");
    Test.assertEqual(r.label, "KCAL DEFICIT");
    Test.assertEqual(Buff.state(r.good), Buff.ACTIVE);
    r = Metrics.deficitReading(1700, 2000);
    Test.assertEqual(r.value, "+300");
    Test.assertEqual(r.label, "KCAL SURPLUS");
    Test.assert(!Metrics.deficitReading(1700, null).known);    // no food logged yet
    return true;
}

// ---- streaks -----------------------------------------------------------------------------------------------------

(:test)
function dayIndexIsDaysSince1970(logger as Test.Logger) as Boolean {
    Test.assertEqual(Streak.dayIndex(1970, 1, 1), 0);
    Test.assertEqual(Streak.dayIndex(2000, 3, 1), 11017);
    Test.assertEqual(Streak.dayIndex(2026, 11, 9), 20766);
    Test.assertEqual(Streak.dayIndex(2027, 1, 1) - Streak.dayIndex(2026, 12, 31), 1);
    Test.assertEqual(Streak.dayIndex(2028, 3, 1) - Streak.dayIndex(2028, 2, 28), 2);   // leap year
    Test.assertEqual(Streak.parseKey("2026-11-09"), 20766);
    Test.assertEqual(Streak.parseKey("2026-08-09"), Streak.dayIndex(2026, 8, 9));    // "08" isn't octal
    Test.assert(Streak.parseKey("nonsense") == null);
    Test.assert(Streak.parseKey(null) == null);
    return true;
}

// Days relative to today = 100
(:test)
function streakCountsDaysInARow(logger as Test.Logger) as Boolean {
    var hits = {93 => true, 94 => false, 95 => true, 96 => true, 97 => true, 98 => true, 99 => true}
        as Dictionary<Number, Boolean>;
    var st = Streak.advance(91, 0, 100, hits);
    Test.assertEqual(st[0], 98);            // counted through the day before yesterday
    Test.assertEqual(st[1], 4);             // 95, 96, 97, 98
    Test.assertEqual(Streak.shown(st[0], st[1], 100, hits, false), 5);   // + yesterday; today not yet
    Test.assertEqual(Streak.shown(st[0], st[1], 100, hits, true), 6);    // today Intense too
    var again = Streak.advance(st[0], st[1], 100, hits);                 // called again the same day: no change
    Test.assertEqual(again[0], 98);
    Test.assertEqual(again[1], 4);
    hits[99] = false;                       // yesterday missed: the streak is gone, until today reaches Intense
    Test.assertEqual(Streak.shown(st[0], st[1], 100, hits, false), 0);
    Test.assertEqual(Streak.shown(st[0], st[1], 100, hits, true), 1);
    return true;
}

(:test)
function streakCarriesOverDaysAndGaps(logger as Test.Logger) as Boolean {
    var hits = {98 => true, 99 => true} as Dictionary<Number, Boolean>;
    var st = Streak.advance(97, 10, 100, hits);   // a stored 10-day streak through day 97
    Test.assertEqual(st[1], 11);
    Test.assertEqual(Streak.shown(st[0], st[1], 100, hits, false), 12);
    hits[100] = true;                             // next morning: 99 gets counted, 100 is yesterday
    st = Streak.advance(st[0], st[1], 101, hits);
    Test.assertEqual(st[0], 99);
    Test.assertEqual(st[1], 12);
    Test.assertEqual(Streak.shown(st[0], st[1], 101, hits, false), 13);
    st = Streak.advance(99, 12, 140, hits);       // the watch off for over a month: start again
    Test.assertEqual(st[0], 138);
    Test.assertEqual(st[1], 0);
    return true;
}
