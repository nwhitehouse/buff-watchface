import Toybox.Application.WatchFaceConfig;
import Toybox.Complications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.WatchUi;

// The Buff face: a buddy whose pose follows the right arc and who fills up with colour as it grows. Each arc tracks
// what the wearer picked in Customize (steps and active calories by default), with its number and label under the
// buddy's arms; the big number is how far the right arc is to its goal (or grams, in calorie deficit mode).
// Speed (lessons from the fēnix 8): everything but the buddy is drawn into one off-screen image once a minute and on
// every wake, then copied to the screen each second; never draw one off-screen image into another. The buddy goes
// on top each second, so it can step through his animation (1-second steps).
// Always-on (wrist down) draws a dim outline face straight to the screen, once a minute.
class BuffView extends WatchUi.WatchFace {

    private var _lowPower as Boolean = false;
    private var _data as BuffData = new BuffData();
    private var _dataKey as Number = -1;        // minute of the day the data was read for

    private var _fDate as FontType?;
    private var _fLabel as FontType?;
    private var _fGrams as FontType?;
    private var _fUnit as FontType?;
    private var _fStreak as FontType?;
    private var _fStat as FontType?;
    private var _fStatLabel as FontType?;
    private var _fGramsOl as FontType?;
    private var _icons as Array<WatchUi.BitmapResource?> = [null, null, null];   // left arc, right arc, streak
    private var _iconMetric as Array<Number> = [-1, -1];   // the metrics the arc icons were loaded for
    private var _theme as Number = -1;          // colour theme the arc colours, digits and buddy were loaded for
    private var _leftCols as Array<Number> = [] as Array<Number>;
    private var _rightCols as Array<Number> = [] as Array<Number>;

    // Time digit images for the 4 positions (hours 0-1, minutes 2-3), reloaded only when a digit changes
    private var _digit as Array<Number> = [-1, -1, -1, -1];
    private var _glyph as Array<WatchUi.BitmapResource?> = [null, null, null, null];
    private var _shadow as Array<WatchUi.BitmapResource?> = [null, null, null, null];
    private var _aodDigit as Array<Number> = [-1, -1, -1, -1];
    private var _aodRing as Array<WatchUi.BitmapResource?> = [null, null, null, null];
    private var _aodFill as Array<WatchUi.BitmapResource?> = [null, null, null, null];

    // The buddy's images for the state on screen
    private var _state as Number = -1;
    private var _dry as Array<WatchUi.BitmapResource> = [] as Array<WatchUi.BitmapResource>;
    private var _wet as Array<WatchUi.BitmapResource> = [] as Array<WatchUi.BitmapResource>;
    private var _over as Array<WatchUi.BitmapResource> = [] as Array<WatchUi.BitmapResource>;
    private var _aodState as Number = -1;
    private var _aodBuddy as WatchUi.BitmapResource?;

    // The off-screen copy of everything but the buddy
    private var _face as Graphics.BufferedBitmapReference?;
    private var _faceKey as Number = -1;        // minute of the day it was drawn for; -1 = redraw
    private var _noLayers as Boolean = false;   // graphics memory too short: draw straight to the screen

    function initialize() {
        WatchFace.initialize();
    }

    function onLayout(dc as Dc) as Void {
        var t0 = System.getTimer();
        _fDate = WatchUi.loadResource(Rez.Fonts.Date) as FontType;
        _fLabel = WatchUi.loadResource(Rez.Fonts.Label) as FontType;
        _fGrams = WatchUi.loadResource(Rez.Fonts.Grams) as FontType;
        _fUnit = WatchUi.loadResource(Rez.Fonts.Unit) as FontType;
        _fStreak = WatchUi.loadResource(Rez.Fonts.Streak) as FontType;
        _fStat = WatchUi.loadResource(Rez.Fonts.Stat) as FontType;
        _fStatLabel = WatchUi.loadResource(Rez.Fonts.StatLabel) as FontType;
        _icons[2] = WatchUi.loadResource(Rez.Drawables.IconStreak) as WatchUi.BitmapResource;
        readConfig();
        loadTheme();
        Perf.log("layout", t0);
        Perf.memory();
    }

    // What the wearer chose in the watch's editor, Customize (resources/configs/watchface.xml): Style = colour theme,
    // Data 1 / 2 = what the left / right arc tracks.
    (:live)
    private function readConfig() as Void {
        var settings = WatchFaceConfig.getSettings(null);   // null: device without watch-face config
        if (settings != null) {
            applyConfig(settings);
        }
    }

    (:mockup)
    private function readConfig() as Void {
        Theme.index = Mock.THEME;
        Slots.left = Mock.LEFT;
        Slots.right = Mock.RIGHT;
    }

    function applyConfig(settings as WatchFaceConfig.Settings) as Void {
        var changed = false;
        var t = Theme.fromStyle(settings.styleId);
        if (t != Theme.index) {
            Theme.index = t;
            changed = true;
        }
        var slots = settings.complicationSettings;
        if (slots != null) {
            for (var i = 0; i < slots.size(); i++) {
                var id = slots[i].complicationId;
                var m = id != null ? Metrics.fromType(id.getType()) : null;
                if (m == null) {
                    continue;
                }
                var which = slots[i].uniqueIdentifier;
                if (which == Slots.LEFT_ID && m != Slots.left) {
                    Slots.left = m;
                    changed = true;
                } else if (which == Slots.RIGHT_ID && m != Slots.right) {
                    Slots.right = m;
                    changed = true;
                }
            }
        }
        if (changed) {
            Refresh.pending = true;   // re-read the data and redraw now
            WatchUi.requestUpdate();
        }
    }

    // Everything the theme colours: the arcs' colours now; the minute digits and the buddy on their next draw.
    private function loadTheme() as Void {
        if (_theme == Theme.index) {
            return;
        }
        _leftCols = Draw.arcColours(BuffGen.LEFT_START, true, Theme.leftGrad());
        _rightCols = Draw.arcColours(BuffGen.RIGHT_START, false, Theme.rightGrad());
        _digit = [-1, -1, -1, -1];
        _state = -1;
        _aodState = -1;
        _faceKey = -1;
        _theme = Theme.index;
    }

    function onUpdate(dc as Dc) as Void {
        var clock = System.getClockTime();
        var key = clock.hour * 60 + clock.min;
        if (Refresh.pending) {   // Customize changed, or new intake from the phone
            Refresh.pending = false;
            _data.settingsChanged();
            _dataKey = -1;
            _faceKey = -1;
        }
        if (key != _dataKey) {
            _data.update();
            _dataKey = key;
        }
        loadTheme();   // the style may have changed in the editor
        loadIcons();
        if (_lowPower) {
            dc.setAntiAlias(true);
            var t0 = System.getTimer();
            drawAod(dc);
            Perf.log("aod", t0);
            return;
        }
        var t1 = System.getTimer();
        loadBuddy(_data.state);
        var face = faceLayer();
        if (face == null) {
            dc.setAntiAlias(true);
            drawFace(dc);
        } else {
            if (_faceKey != key) {
                renderFace(face, key);
            }
            dc.drawBitmap(0, 0, face);
        }
        drawBuddy(dc, clock.sec);
        Perf.tick(System.getTimer() - t1);
    }

    function onEnterSleep() as Void {
        _lowPower = true;
        WatchUi.requestUpdate();
    }

    function onExitSleep() as Void {
        _lowPower = false;
        _faceKey = -1;   // redraw: the off-screen copy may not survive sleep
        WatchUi.requestUpdate();
    }

    function onShow() as Void {
        _faceKey = -1;
    }

    // ---- off-screen face ------------------------------------------------------------------------

    // Lives in the graphics pool, which can purge it at any time: recreate on demand, and give up (draw straight to
    // the screen) if it can't be allocated, rather than retrying every second.
    private function faceLayer() as Graphics.BufferedBitmap? {
        var b = _face != null ? (_face as Graphics.BufferedBitmapReference).get() : null;
        if (b == null && !_noLayers) {
            try {
                _face = Graphics.createBufferedBitmap({:width => Layout.SIZE, :height => Layout.SIZE});
            } catch (e) {
                _face = null;
            }
            b = _face != null ? (_face as Graphics.BufferedBitmapReference).get() : null;
            _faceKey = -1;
            _noLayers = b == null;
        }
        return b as Graphics.BufferedBitmap?;
    }

    private function renderFace(face as Graphics.BufferedBitmap, key as Number) as Void {
        var t0 = System.getTimer();
        var dc = face.getDc();
        dc.setAntiAlias(true);
        drawFace(dc);
        _faceKey = key;
        Perf.log("face", t0);   // also writes the section times and last minute's per-second times, as one line
    }

    private function drawFace(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        var t = System.getTimer();
        drawArcs(dc);
        t = Perf.section("arcs", t);
        drawTime(dc);
        t = Perf.section("time", t);
        Draw.centred(dc, Layout.CX, BuffGen.DATE_BASE, _fDate as FontType, BuffGen.ASCENT_DATE, _data.dateText, BuffGen.DATE_TRACK,
            Colors.DATE);
        if (_data.state != Buff.FLATLINING || !_data.known) {   // flatlining blinks: drawn each second (drawBuddy)
            Draw.centred(dc, Layout.CX, BuffGen.LABEL_BASE, _fLabel as FontType, BuffGen.ASCENT_LABEL, _data.label, BuffGen.LABEL_TRACK,
                Colors.LABEL);
        }
        drawStats(dc);
        drawCentre(dc);
        drawStreak(dc);
        Perf.section("text", t);
    }

    // The left arc fills up the left (clockwise on screen), the right arc up the right (anticlockwise), over thin
    // tracks; a dark socket at each arc's start.
    private function drawArcs(dc as Dc) as Void {
        var span = BuffGen.ARC_SPAN;
        Draw.arc(dc, BuffGen.LEFT_START, span, true, BuffGen.TRACK_W, Colors.TRACK, 0, 0);
        Draw.arc(dc, BuffGen.RIGHT_START, span, false, BuffGen.TRACK_W, Colors.TRACK, 0, 0);
        Draw.gradientArc(dc, BuffGen.LEFT_START, sweep(_data.left.frac), true, _leftCols);
        Draw.gradientArc(dc, BuffGen.RIGHT_START, sweep(_data.right.frac), false, _rightCols);
        var ends = [BuffGen.LEFT_START, BuffGen.RIGHT_START];
        for (var i = 0; i < 2; i++) {
            var p = Draw.onArc(ends[i]);
            dc.setColor(Colors.PIN_RING, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(p[0], p[1], 6);
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(p[0], p[1], 4);
        }
    }

    // Each arc's reading: a number and a label each side of the buddy's legs, and its icon just inside the arc's
    // bottom end. The left side is neutral, the right side (the buddy's) in the theme's colour.
    private function drawStats(dc as Dc) as Void {
        var readings = [_data.left, _data.right];
        for (var i = 0; i < 2; i++) {
            drawStat(dc, i, readings[i]);
        }
    }

    function drawStat(dc as Dc, side as Number, r as Reading) as Void {
        var nf = _fStat as FontType;
        var cx = side == 0 ? BuffGen.STAT_CX_L : BuffGen.STAT_CX_R;
        var icon = side == 0 ? BuffGen.ICON_LEFT : BuffGen.ICON_RIGHT;
        var bitmap = _icons[side];
        if (bitmap != null) {   // white icons, tinted
            dc.drawBitmap2(icon[0], icon[1], bitmap, {:tintColor => side == 0 ? Theme.leftIcon() : Theme.accent()});
        }
        dc.setColor(side == 0 ? Theme.leftValue() : Theme.accent(), Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx - dc.getTextWidthInPixels(r.value, nf) / 2, Draw.textTop(BuffGen.STAT_NUM_BASE,
            BuffGen.ASCENT_STAT), nf, r.value, Graphics.TEXT_JUSTIFY_LEFT);
        Draw.centred(dc, cx, BuffGen.STAT_LABEL_BASE, _fStatLabel as FontType, BuffGen.ASCENT_STAT_LABEL, r.label,
            BuffGen.STAT_LABEL_TRACK, Colors.STAT_LABEL);
    }

    // Each arc's icon follows what it tracks
    private function loadIcons() as Void {
        var ms = [_data.left.metric, _data.right.metric];
        for (var i = 0; i < 2; i++) {
            if (_iconMetric[i] != ms[i]) {
                _icons[i] = WatchUi.loadResource(Metrics.icon(ms[i])) as WatchUi.BitmapResource;
                _iconMetric[i] = ms[i];
                _faceKey = -1;
            }
        }
    }

    private function sweep(frac as Float) as Number {
        var f = frac < 0.0 ? 0.0 : (frac > 1.0 ? 1.0 : frac);
        return Math.round(BuffGen.ARC_SPAN * f).toNumber();
    }

    // "72 %" (how far the right arc is to its goal) or, in deficit mode, "117 g": the number and a small unit on one
    // baseline, centred as a row.
    private function drawCentre(dc as Dc) as Void {
        var gf = _fGrams as FontType;
        var uf = _fUnit as FontType;
        var g = _data.centre;
        var wg = dc.getTextWidthInPixels(g, gf);
        var x = Layout.CX - (wg + Layout.GRAMS_GAP + dc.getTextWidthInPixels(_data.unit, uf)) / 2;
        var base = BuffGen.GRAMS_BASE;
        var color = _data.known && _data.state == Buff.FLATLINING ? Colors.GRAMS_DYING : Theme.accent();
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, Draw.textTop(base, BuffGen.ASCENT_GRAMS), gf, g, Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(x + wg + Layout.GRAMS_GAP, Draw.textTop(base, BuffGen.ASCENT_UNIT), uf, _data.unit,
            Graphics.TEXT_JUSTIFY_LEFT);
    }

    // "🔥 5-DAY STREAK" in gold under the big number; nothing until there's a streak.
    private function drawStreak(dc as Dc) as Void {
        if (_data.streak < 1) {
            return;
        }
        var f = _fStreak as FontType;
        var text = _data.streak + "-DAY STREAK";
        var w = BuffGen.STREAK_ICON + BuffGen.STREAK_GAP + dc.getTextWidthInPixels(text, f) - 1;   // less the tracking
        var x = Layout.CX - w / 2;
        dc.drawBitmap(x, BuffGen.STREAK_ICON_TOP, _icons[2] as WatchUi.BitmapResource);
        dc.setColor(Colors.STREAK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + BuffGen.STREAK_ICON + BuffGen.STREAK_GAP, Draw.textTop(BuffGen.STREAK_BASE, BuffGen.ASCENT_STREAK),
            f, text, Graphics.TEXT_JUSTIFY_LEFT);
    }

    // ---- buddy ----------------------------------------------------------------------------------

    private function loadBuddy(s as Number) as Void {
        if (s == _state) {
            return;
        }
        var t0 = System.getTimer();
        _dry = load(BuffGen.dry(Theme.index, s));
        _wet = load(BuffGen.wet(Theme.index, s));
        _over = load(BuffGen.over(Theme.index, s));
        _state = s;
        Perf.log("buddy " + s, t0);
    }

    private function load(ids as Array<ResourceId>) as Array<WatchUi.BitmapResource> {
        var out = [] as Array<WatchUi.BitmapResource>;
        for (var i = 0; i < ids.size(); i++) {
            out.add(WatchUi.loadResource(ids[i]) as WatchUi.BitmapResource);
        }
        return out;
    }

    // The pose for this second (the design's 2-second cycle), filled up to the fill line, then the overlay of the
    // 3-second cycle (zzz, sweat, sparkles). The FLATLINING label blinks.
    private function drawBuddy(dc as Dc, sec as Number) as Void {
        var s = _state;
        var nd = _dry.size();
        var nw = _wet.size();
        if (nd > 0) {
            var i = sec % nd;
            var xy = BuffGen.DRY_XY[s][i];
            dc.drawBitmap(xy[0], xy[1], _dry[i]);
        }
        if (nw > 0) {
            var i = sec % nw;
            var xy = BuffGen.WET_XY[s][i];
            if (nd == 0) {   // insane: full
                dc.drawBitmap(xy[0], xy[1], _wet[i]);
            } else {
                var y = (BuffGen.FILL_Y0 - BuffGen.FILL_DY * _data.progress).toNumber();
                if (y < xy[1] + _wet[i].getHeight()) {
                    dc.setClip(0, y, Layout.SIZE, Layout.SIZE - y);
                    dc.drawBitmap(xy[0], xy[1], _wet[i]);
                    dc.clearClip();
                }
            }
        }
        if (_over.size() > 0) {
            var k = sec % _over.size();
            var xy = BuffGen.OVER_XY[s][k];
            dc.drawBitmap(xy[0], xy[1], _over[k]);
        }
        if (s == Buff.FLATLINING && _data.known) {
            Draw.centred(dc, Layout.CX, BuffGen.LABEL_BASE, _fLabel as FontType, BuffGen.ASCENT_LABEL, _data.label, BuffGen.LABEL_TRACK,
                sec % 2 == 1 ? Colors.DYING_DIM : Colors.DYING);
        }
    }

    // ---- editor (Customize) ---------------------------------------------------------------------

    // An arc's data slot as the editor highlights it: the arc and its number, label and icon
    function slotRef(id as Object or Null) as ComplicationDrawableRef? {
        var side = id == Slots.LEFT_ID ? 0 : (id == Slots.RIGHT_ID ? 1 : -1);
        if (side < 0) {
            return null;
        }
        var d = new SlotDrawable(self, side);
        return new WatchUi.ComplicationDrawableRef({:drawable => d, :boundingBox => d.getBoundingBox()});
    }

    function drawSlot(dc as Dc, side as Number) as Void {
        dc.setAntiAlias(true);
        if (side == 0) {
            Draw.gradientArc(dc, BuffGen.LEFT_START, sweep(_data.left.frac), true, _leftCols);
        } else {
            Draw.gradientArc(dc, BuffGen.RIGHT_START, sweep(_data.right.frac), false, _rightCols);
        }
        drawStat(dc, side, side == 0 ? _data.left : _data.right);
    }

    // ---- time -----------------------------------------------------------------------------------

    // Pen x of the 4 digits, as the design's CSS lays them out: letter-spacing -3 after every digit; the minutes
    // block starts 4px into the hours' (margin-left -4 and padding 3); the whole row centred.
    private function timeX(digits as Array<Number>) as Array<Number> {
        var a = BuffGen.TIME_ADV;
        var t = BuffGen.TIME_TRACK;
        var hours = a[digits[0]] + a[digits[1]];
        var mins = a[digits[2]] + a[digits[3]];
        var left = Layout.CX - (hours + 2 * t + mins + 2 * t - 1) / 2;
        var m = left + hours + 2 * t - 1;
        return [left, left + a[digits[0]] + t, m, m + a[digits[2]] + t];
    }

    // Hours then minutes; each half's shadows go down before its glyphs, so the minutes' shadow falls on the hours.
    private function drawTime(dc as Dc) as Void {
        var digits = [_data.hour / 10, _data.hour % 10, _data.minute / 10, _data.minute % 10];
        for (var pos = 0; pos < 4; pos++) {
            loadDigit(pos, digits[pos]);
        }
        var xs = timeX(digits);
        for (var half = 0; half < 2; half++) {
            var off = half == 0 ? BuffGen.OFF_HOUR : BuffGen.OFF_MIN;
            for (var pos = half * 2; pos < half * 2 + 2; pos++) {
                var o = off[digits[pos]];
                dc.drawBitmap(xs[pos] + o[2], BuffGen.TIME_BASE + o[3], _shadow[pos] as WatchUi.BitmapResource);
            }
            for (var pos = half * 2; pos < half * 2 + 2; pos++) {
                var o = off[digits[pos]];
                dc.drawBitmap(xs[pos] + o[0], BuffGen.TIME_BASE + o[1], _glyph[pos] as WatchUi.BitmapResource);
            }
        }
    }

    private function loadDigit(pos as Number, d as Number) as Void {
        if (_digit[pos] == d) {
            return;
        }
        // Cream minutes in cream; the other themes' minutes are white, the hours' images (with the minutes' shadow)
        var glyphs = pos < 2 || !Theme.creamMinutes() ? BuffGen.glyphsHour() : BuffGen.glyphsMin();
        _glyph[pos] = WatchUi.loadResource(glyphs[d]) as WatchUi.BitmapResource;
        _shadow[pos] = WatchUi.loadResource((pos < 2 ? BuffGen.shadowsHour() : BuffGen.shadowsMin())[d]) as WatchUi.BitmapResource;
        _digit[pos] = d;
    }

    // ---- always-on (wrist down) -----------------------------------------------------------------

    // Pure black; thin dim arcs; dim date; outline time; the buddy's outline in his current pose; outline number.
    // No fill, glow, shadows or animation (it's redrawn once a minute). Shifted up to 2px each minute (burn-in).
    private function drawAod(dc as Dc) as Void {
        if (_fGramsOl == null) {
            _fGramsOl = WatchUi.loadResource(Rez.Fonts.GramsOl) as FontType;
        }
        if (_aodState != _data.state) {
            _aodBuddy = WatchUi.loadResource(BuffGen.aod(Theme.index, _data.state)) as WatchUi.BitmapResource;
            _aodState = _data.state;
        }
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        var shift = Layout.AOD_SHIFT[_data.minute % Layout.AOD_SHIFT.size()];
        var ox = shift[0];
        var oy = shift[1];
        var span = BuffGen.ARC_SPAN;
        Draw.arc(dc, BuffGen.LEFT_START, span, true, 2, Colors.AOD_TRACK, ox, oy);
        Draw.arc(dc, BuffGen.RIGHT_START, span, false, 2, Colors.AOD_TRACK, ox, oy);
        Draw.arc(dc, BuffGen.LEFT_START, sweep(_data.left.frac), true, Layout.AOD_ARC_W, Theme.aodLeft(), ox, oy);
        Draw.arc(dc, BuffGen.RIGHT_START, sweep(_data.right.frac), false, Layout.AOD_ARC_W, Theme.aodRight(), ox, oy);
        Draw.centred(dc, Layout.CX + ox, BuffGen.DATE_BASE + oy, _fDate as FontType, BuffGen.ASCENT_DATE, _data.dateText,
            BuffGen.DATE_TRACK, Colors.AOD_DATE);
        drawAodTime(dc, ox, oy);
        var xy = BuffGen.AOD_XY[_data.state];
        dc.drawBitmap(xy[0] + ox, xy[1] + oy, _aodBuddy as WatchUi.BitmapResource);
        var g = _data.centre;
        var gf = _fGramsOl as FontType;
        var uf = _fUnit as FontType;
        var wg = dc.getTextWidthInPixels(g, gf);
        var x = Layout.CX + ox - (wg + Layout.GRAMS_GAP + dc.getTextWidthInPixels(_data.unit, uf)) / 2;
        dc.setColor(Theme.aodRight(), Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, Draw.textTop(BuffGen.GRAMS_BASE + oy, BuffGen.ASCENT_GRAMS_OL), gf, g, Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(x + wg + Layout.GRAMS_GAP, Draw.textTop(BuffGen.GRAMS_BASE + oy, BuffGen.ASCENT_UNIT), uf,
            _data.unit, Graphics.TEXT_JUSTIFY_LEFT);
    }

    // Outline digits: hours grey; minutes dim cream with a black fill so they cut cleanly in front of the hours.
    private function drawAodTime(dc as Dc, ox as Number, oy as Number) as Void {
        var digits = [_data.hour / 10, _data.hour % 10, _data.minute / 10, _data.minute % 10];
        var xs = timeX(digits);
        for (var pos = 0; pos < 4; pos++) {
            var d = digits[pos];
            if (_aodDigit[pos] != d) {
                _aodRing[pos] = WatchUi.loadResource(BuffGen.aodGlyphs()[d]) as WatchUi.BitmapResource;
                _aodFill[pos] = pos >= 2 ? WatchUi.loadResource(BuffGen.aodFills()[d]) as WatchUi.BitmapResource : null;
                _aodDigit[pos] = d;
            }
            var o = BuffGen.OFF_AOD[d];
            var x = xs[pos] + ox;
            var y = BuffGen.TIME_BASE + oy;
            if (pos >= 2) {
                dc.drawBitmap(x + o[2], y + o[3], _aodFill[pos] as WatchUi.BitmapResource);
            }
            dc.drawBitmap2(x + o[0], y + o[1], _aodRing[pos] as WatchUi.BitmapResource,
                {:tintColor => pos < 2 ? Colors.AOD_HOURS : Theme.aodMinutes()});
        }
    }
}

// The watch's editor (Customize): passes live changes to the view, picks an arc's data slot from a tap, and gives the
// editor a drawable to highlight the slot being edited.
class BuffConfigDelegate extends WatchUi.WatchFaceDelegate {

    private var _view as BuffView;

    function initialize(view as BuffView) {
        WatchFaceDelegate.initialize();
        _view = view;
    }

    function onWatchFaceConfigEdited(options as {:configId as WatchFaceConfig.Id, :type as WatchUi.WatchFaceConfigType?,
                                                 :committed as Boolean}) as Void {
        var id = options[:configId] as WatchFaceConfig.Id?;
        if (id != null) {
            var settings = WatchFaceConfig.getSettings(id);
            if (settings != null) {
                _view.applyConfig(settings);
            }
        }
    }

    // The editor shows this drawable over the slot being edited
    function getComplicationDrawable(complication as ComplicationRef) as Drawable or ComplicationDrawableRef or Null {
        return _view.slotRef(complication.uniqueIdentifier);
    }

    // Touch: a tap on either half picks that arc's data slot
    function onTap(clickEvent as ClickEvent) as Boolean {
        var xy = clickEvent.getCoordinates();
        var slot = Slots.at(xy[0], xy[1]);
        if (slot != null) {
            setSelectedComplication(slot);
            return true;
        }
        return false;
    }
}

// The editor's view of one arc's data slot (BuffView.slotRef): the region around its number, label and icon.
class SlotDrawable extends WatchUi.Drawable {

    private var _view as BuffView;
    private var _side as Number;

    function initialize(view as BuffView, side as Number) {
        var b = Slots.box(side);
        Drawable.initialize({:locX => b[0], :locY => b[1], :width => b[2], :height => b[3]});
        _view = view;
        _side = side;
    }

    function getBoundingBox() as Graphics.BoundingBox {
        var box = new Graphics.BoundingBox();
        box.addRectangle(locX.toNumber(), locY.toNumber(), width.toNumber(), height.toNumber());
        return box;
    }

    function draw(dc as Dc) as Void {
        _view.drawSlot(dc, _side);
    }
}

// Timings, one line per face redraw ("face 240 ms | arcs 30 time 50 text 20 | tick avg 12 max 40 n 60"): the
// face's sections, and the once-a-second redraws (copy + buddy) since the last line. A sideloaded app's
// System.println goes to GARMIN/APPS/LOGS/BUFFFACE.TXT on the watch only if that file exists (`LOG=1 make
// sideload` creates it; the next sideload copies it back to bin/). Each line is a write to the watch's storage.
module Perf {
    var count as Number = 0;
    var sections as String = "";
    var tickSum as Number = 0;
    var tickMax as Number = 0;
    var tickN as Number = 0;

    (:debug) const MAX = 100000;
    (:release) const MAX = 300;

    function log(what as String, t0 as Number) as Void {
        if (count < MAX) {
            count++;
            var ticks = tickN > 0 ? " | tick avg " + tickSum / tickN + " max " + tickMax + " n " + tickN : "";
            System.println(what + " " + (System.getTimer() - t0) + " ms" + (sections.length() > 0 ? " |" + sections : "")
                + ticks);
        }
        sections = "";
        tickSum = 0;
        tickMax = 0;
        tickN = 0;
    }

    function memory() as Void {
        var s = System.getSystemStats();
        System.println("memory " + s.usedMemory + " / " + s.totalMemory);
    }

    function section(what as String, t0 as Number) as Number {
        var now = System.getTimer();
        if (count < MAX) {
            sections += " " + what + " " + (now - t0);
        }
        return now;
    }

    // One once-a-second redraw's time (copying the face plus the buddy)
    function tick(ms as Number) as Void {
        tickSum += ms;
        tickN++;
        if (ms > tickMax) {
            tickMax = ms;
        }
    }
}
