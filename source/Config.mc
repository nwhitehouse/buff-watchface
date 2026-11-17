import Toybox.Lang;

// Build-time options. Change a value and rebuild (`make build`, `make sideload`). Everything a wearer picks on the
// watch (colour, what each arc tracks) is in Customize instead: see README.md.
module Config {

    // ---- Calories ------------------------------------------------------------------------------------------------
    // Garmin's on-watch picker has a single "Calories" choice. Buff shows ACTIVE calories for it (what you burned
    // above your resting rate, estimated from the weight, height, age and sex in your Garmin profile). Set this to
    // true to show Garmin's total for the day instead.
    const CALORIES_TOTAL = false;
    const ACTIVE_KCAL_GOAL = 500;       // the arc, and the buddy when calories are on the right, are full here
    const TOTAL_KCAL_GOAL = 2500;

    // ---- Scales for readings that have no goal -------------------------------------------------------------------
    // The arc runs from the first number to the second. For stress, resting heart rate and recovery time, lower is
    // better: the arc shows the reading, the buddy gets stronger as it falls.
    const RESTING_HR_SCALE = [30, 100] as Array<Number>;   // bpm
    const RECOVERY_SCALE = [0, 72] as Array<Number>;       // hours
    const PULSE_OX_SCALE = [80, 100] as Array<Number>;     // %

    // ---- Optional: calorie deficit mode (docs/deficit-mode.md) --------------------------------------------------
    // Off unless you set INTAKE_URL in source/secrets.mc to your own server, which tells the watch what you ate.
    // Then the right arc, the buddy and the centre number follow your calorie deficit (burned - eaten) instead of
    // the right arc's Customize choice, and the centre shows it as grams of fat (deficit / 7.7).
    const DEFICIT_TARGET_KCAL = 1500;   // Insane from here (~195 g); Intense from 1,000, Active from 250
}
