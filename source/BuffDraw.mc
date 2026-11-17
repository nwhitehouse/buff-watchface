import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;

// Screen geometry and colours that aren't generated (BuffGen has the design's layout).
module Layout {
    const CX = 227;
    const CY = 227;
    const SIZE = 454;
    const ARC_STEP = 3;             // gradient arcs are drawn in 3-degree segments (no banding, few calls)
    const SHADOW_DY = 3;            // the design's mLift drop shadow under the arcs
    const GRAMS_GAP = 5;            // "208" g: the flex gap (design 4, scaled with the text)
    const AOD_SHIFT = [[0, 0], [2, 0], [2, 2], [0, 2], [-2, 2], [-2, 0], [-2, -2], [0, -2], [2, -2]]
        as Array<Array<Number>>;    // always-on: moved a little each minute (AMOLED burn-in)
    const AOD_ARC_W = 4;
}

module Colors {
    const TRACK = 0x242424;
    const DATE = 0xBDBDBD;
    const LABEL = 0xFFFFFF;
    const DYING = 0xFF7B6B;         // FLATLINING
    const DYING_DIM = 0x733730;     // DYING at the design's 45% opacity, for its once-a-second blink
    const GRAMS_DYING = 0xC9C0B0;   // the big number while flatlining
    const STREAK = 0xE2C477;
    const STAT_LABEL = 0xBDBDBD;    // the labels under the arcs' numbers, as the date
    const PIN_RING = 0x5A5A5A;
    // Always-on: dim, mostly black (under 10% of the screen's light)
    const AOD_TRACK = 0x151515;
    const AOD_DATE = 0x6A6A6A;
    const AOD_HOURS = 0xB5B5B5;
}

// The colour theme chosen in the watch's editor (Customize > Style): Cream (the original design), White, Ice, Ember,
// Coral or Mint (BuffGen's tables, from THEMES in tools/build_assets.py). The right arc, the buddy and the big number
// take the accent; the left arc stays neutral.
module Theme {
    var index as Number = BuffGen.DEFAULT_THEME;

    function accent() as Number { return BuffGen.ACCENT[index]; }           // the buddy's fill, the right side
    function leftIcon() as Number { return BuffGen.LEFT_ICON[index]; }
    function leftValue() as Number { return BuffGen.LEFT_VALUE[index]; }
    function leftGrad() as Array<Number> { return BuffGen.LEFT_GRAD[index]; }
    function rightGrad() as Array<Number> { return BuffGen.RIGHT_GRAD[index]; }
    function creamMinutes() as Boolean { return BuffGen.CREAM_MINUTES[index]; }
    function aodLeft() as Number { return BuffGen.AOD_LEFT[index]; }
    function aodRight() as Number { return BuffGen.AOD_RIGHT[index]; }
    function aodMinutes() as Number { return BuffGen.AOD_MINUTES[index]; }

    // Style id 1..THEME_COUNT -> index; anything else (no style yet) -> cream
    function fromStyle(id as Number?) as Number {
        return id != null && id >= 1 && id <= BuffGen.THEME_COUNT ? id - 1 : BuffGen.DEFAULT_THEME;
    }
}

module Draw {

    // Connect IQ draws custom bitmap-font glyphs 1px lower than their .fnt yoffset says.
    const FONT_Y_NUDGE = -1;

    // drawText() y for a baseline, given the font's ascent (BuffGen.ASCENT_*).
    function textTop(baseline as Number, ascent as Number) as Number {
        return baseline - ascent + FONT_Y_NUDGE;
    }

    // Text centred on cx by its glyphs: tracked fonts carry their letter-spacing in each advance, so the measured
    // width includes one trailing `tracking` (the design balances it with padding-left).
    function centred(dc as Dc, cx as Number, baseline as Number, font as FontType, ascent as Number, text as String,
                     tracking as Number, color as Number) as Void {
        var w = dc.getTextWidthInPixels(text, font) - tracking;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx - w / 2, textTop(baseline, ascent), font, text, Graphics.TEXT_JUSTIFY_LEFT);
    }

    // Colours along a progress arc, one per degree from its start (0..ARC_SPAN), from a 3-stop vertical gradient over
    // GRAD_TOP..GRAD_BOT. Computed once, so drawing an arc does no trigonometry or colour maths.
    function arcColours(startDeg as Number, clockwise as Boolean, stops as Array<Number>) as Array<Number> {
        var dir = clockwise ? -1 : 1;
        var out = new Array<Number>[BuffGen.ARC_SPAN + 1];
        for (var i = 0; i <= BuffGen.ARC_SPAN; i++) {
            out[i] = gradientAt(stops, yOnArc(startDeg + dir * (i + 0.5)));
        }
        return out;
    }

    // Progress arc: a soft drop shadow below, then ARC_STEP-degree segments in the precomputed colours, round caps.
    // Connect IQ degrees (0 = 3 o'clock, anticlockwise positive), whole degrees.
    function gradientArc(dc as Dc, startDeg as Number, sweep as Number, clockwise as Boolean, colours as Array<Number>) as Void {
        if (sweep < 1) {
            return;
        }
        var dir = clockwise ? -1 : 1;
        var arcDir = clockwise ? Graphics.ARC_CLOCKWISE : Graphics.ARC_COUNTER_CLOCKWISE;
        var endDeg = startDeg + dir * sweep;
        var r = BuffGen.ARC_R;
        var sw = BuffGen.ARC_W + 2;
        dc.setColor(Graphics.createColor(150, 0, 0, 0), Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(sw);
        dc.drawArc(Layout.CX, Layout.CY + Layout.SHADOW_DY, r, arcDir, norm(startDeg), norm(endDeg));
        capAt(dc, startDeg, 0, Layout.SHADOW_DY, sw / 2);
        capAt(dc, endDeg, 0, Layout.SHADOW_DY, sw / 2);
        dc.setPenWidth(BuffGen.ARC_W);
        // Each segment overlaps the next by 1 degree, which then paints over it: no anti-aliasing seams.
        var step = Layout.ARC_STEP;
        for (var i = 0; i < sweep; i += step) {
            var len = i + step < sweep ? step + 1 : sweep - i;
            dc.setColor(colours[i + len / 2], Graphics.COLOR_TRANSPARENT);
            dc.drawArc(Layout.CX, Layout.CY, r, arcDir, norm(startDeg + dir * i), norm(startDeg + dir * (i + len)));
        }
        dc.setColor(colours[0], Graphics.COLOR_TRANSPARENT);
        capAt(dc, startDeg, 0, 0, BuffGen.ARC_W / 2);
        dc.setColor(colours[sweep], Graphics.COLOR_TRANSPARENT);
        capAt(dc, endDeg, 0, 0, BuffGen.ARC_W / 2);
    }

    // A plain round-capped arc (tracks, always-on arcs)
    function arc(dc as Dc, startDeg as Number, sweep as Number, clockwise as Boolean, w as Number, color as Number,
                 ox as Number, oy as Number) as Void {
        if (sweep < 1) {
            return;
        }
        var endDeg = startDeg + (clockwise ? -sweep : sweep);
        dc.setPenWidth(w);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(Layout.CX + ox, Layout.CY + oy, BuffGen.ARC_R, clockwise ? Graphics.ARC_CLOCKWISE : Graphics.ARC_COUNTER_CLOCKWISE,
            norm(startDeg), norm(endDeg));
        capAt(dc, startDeg, ox, oy, w / 2);
        capAt(dc, endDeg, ox, oy, w / 2);
    }

    function yOnArc(deg as Float or Number) as Float {
        return (Layout.CY - BuffGen.ARC_R * Math.sin(Math.toRadians(deg))).toFloat();
    }

    // Colour of a 3-stop vertical gradient (0, 0.5, 1) at screen y.
    function gradientAt(stops as Array<Number>, y as Float) as Number {
        var t = (y - BuffGen.GRAD_TOP) / (BuffGen.GRAD_BOT - BuffGen.GRAD_TOP);
        t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
        return t < 0.5 ? blend(stops[0], stops[1], t * 2) : blend(stops[1], stops[2], (t - 0.5) * 2);
    }

    // Round cap: a filled circle on the arc at `deg`, shifted by (ox, oy).
    function capAt(dc as Dc, deg as Float or Number, ox as Number, oy as Number, r as Number) as Void {
        var p = onArc(deg);
        dc.fillCircle(p[0] + ox, p[1] + oy, r);
    }

    function onArc(deg as Float or Number) as Array<Number> {
        var rad = Math.toRadians(deg);
        return [Math.round(Layout.CX + BuffGen.ARC_R * Math.cos(rad)).toNumber(),
                Math.round(Layout.CY - BuffGen.ARC_R * Math.sin(rad)).toNumber()];
    }

    // a -> b by t (0..1), per RGB channel.
    function blend(a as Number, b as Number, t as Float) as Number {
        var r = ((a >> 16) & 0xFF) + (((b >> 16) & 0xFF) - ((a >> 16) & 0xFF)) * t;
        var g = ((a >> 8) & 0xFF) + (((b >> 8) & 0xFF) - ((a >> 8) & 0xFF)) * t;
        var bl = (a & 0xFF) + ((b & 0xFF) - (a & 0xFF)) * t;
        return (r.toNumber() << 16) | (g.toNumber() << 8) | bl.toNumber();
    }

    function norm(deg as Number) as Number {
        var d = deg % 360;
        return d < 0 ? d + 360 : d;
    }
}
