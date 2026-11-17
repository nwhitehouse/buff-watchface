#!/usr/bin/env python3
"""Build the Buff face's images, fonts and layout (resources/gen, resources/fonts, source/gen/BuffGen.mc) from the
design (design/muscle.html, the "Musclegotchi" buddy). The results are committed, so you only need this if you change
the design, the colours or the layout.

The buddy is the design's own SVG, rendered here for every theme, state and animation frame, so the watch only
copies images. It animates in 1-second steps (the watch redraws once a second while the screen is on), so each state
is a few frames:
  buddy_<t>_<s>_d<f>.png   the pose "dry": dark body, light outline and lines
  buddy_<t>_<s>_w<f>.png   the same pose "wet": filled with the theme's colour, dark lines. The watch draws the dry
                           image, then the wet one clipped to below the fill line, so the body fills up with progress.
  buddy_<t>_<s>_o<k>.png   overlays on their own 3-second cycle: zzz (resting), sweat (intense), sparkles (insane)
  buddy_<t>_<s>_aod.png    always-on: the pose's outline only, dim
Themes t: THEMES below. States s: 0 flatlining, 1 resting, 2 active, 3 intense, 4 insane (the design's levels 0, 1,
3, 4, 5). Images that come out the same in several themes are written once and shared.
Also: the time digits (Barlow Condensed Bold, gradient + drop shadow, like the design's CSS), always-on outline
digits, the arc icons (Lucide), and the bitmap fonts (tools/bmfont.py).

Usage: python3 tools/build_assets.py      (or `make assets`; needs Pillow with raqm, numpy and rsvg-convert)
"""
import hashlib
import math
import os
import re
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import bmfont     # noqa: E402  (bitmap fonts, icons)
import render     # noqa: E402  (SVG rendering, text metrics, shadows)

DESIGN = os.path.join(ROOT, "design", "muscle.html")
OUT = os.path.join(ROOT, "resources", "gen")
FONT_OUT = os.path.join(ROOT, "resources", "fonts")
GEN = os.path.join(ROOT, "source", "gen")
FONTS = os.path.join(ROOT, "tools", "fonts")
BOLD = os.path.join(FONTS, "BarlowCondensed-Bold.woff2")        # Barlow Condensed (OFL)
SEMIBOLD = os.path.join(FONTS, "BarlowCondensed-SemiBold.ttf")
C = 227
SS = 4

# ---- the design's layout (CSS / SVG in muscle.html) ------------------------------------------------------
# Buddy: <svg width=208 height=200 viewBox="16 24 168 162"> at left 123, top 140 ("meet": uniform scale, centred)
FK = min(208 / 168, 200 / 162)
FX = 123 + (208 - 168 * FK) / 2
FY = 140
ARC_R, ARC_W, TRACK_W, ARC_SPAN = 205, 16, 4, 110
LEFT_START, RIGHT_START = 235, 305          # Connect IQ degrees: the left arc fills clockwise up the left, the right
GRAD_TOP, GRAD_BOT = 40, 420                # arc anticlockwise up the right; gradients run over y 40..420
# Bigger than the design, for reading on the wrist: the date, level name and the arcs' numbers 1.6x; time, the big
# number, streak and icons about 1.3x. The buddy is the design's size.
DATE_TOP, DATE_PX, DATE_TRACK = 20, 24, 4                       # design 15px, letter-spacing 3
TIME_TOP, TIME_PX, TIME_LH, TIME_TRACK = 44, 84, 0.85, -4       # design 66px, letter-spacing -3
LABEL_TOP, LABEL_PX, LABEL_TRACK = 319, 26, 4                   # design 16px, letter-spacing 3
GRAMS_TOP, GRAMS_PX, UNIT_PX = 348, 58, 25                       # the big number (design 46 / 20px)
STREAK_BASE, STREAK_PX, STREAK_TRACK = 424, 18, 1     # "🔥 5-DAY STREAK"
STREAK_ICON, STREAK_ICON_TOP, STREAK_GAP = 15, 409, 6
# Each arc's reading: a number and a label each side of the buddy's legs, under his arms. Column centres x, number and
# label baselines.
STAT_CX = (108, 346)                                            # "KCAL SURPLUS" clears the right arc by 8px
STAT_NUM_BASE, STAT_LABEL_BASE = 290, 311
STAT_PX, STAT_LABEL_PX, STAT_LABEL_TRACK = 46, 18, 1
# Each arc's icon just inside its bottom end, level with the big number and clear of the streak line. Top-left corners.
ICON_PX, ICON_STROKE = 30, 2.3                                  # design 22px
ICONS = {"left": (124, 386), "right": (454 - 124 - ICON_PX, 386)}
# An icon per metric (Metrics.icon in source/Metrics.mc), Lucide (tools/bmfont.py): white, tinted on the watch
METRIC_ICONS = ["footprints", "flame", "zap", "chevrons-up", "battery-charging", "activity", "moon", "heart",
                "hourglass", "droplet", "battery-medium"]
STREAK_GOLD = "#E2C477"
SWEAT_SCALE = 2                              # sweat drops 2x the design's

# Colour themes, in the order Customize > Style lists them (style ids 1..6; Cream, the original design, is the
# default). In the others the accent fills the buddy and colours the right side (arc, number, icon, big number); the
# body and the fill's lines are a neutral dark; the minutes are white like the hours; the left side is a darker grey.
# (key, Style label, accent, the right arc's colour at the bottom of the screen)
THEMES = [
    ("white", "White", "#F2F2F2", "#CBCBCB"),
    ("cream", "Cream", "#E8D5A8", "#B49D6E"),
    ("ice", "Ice", "#5CE1FF", "#2A9CC0"),
    ("ember", "Ember", "#FF8A3D", "#C3581A"),
    ("coral", "Coral", "#FF5A4E", "#C03327"),
    ("mint", "Mint", "#7CFFB2", "#3EBC76"),
]
CREAM = 1


def mix(a, b, k):
    a, b = render.hexrgb(a), render.hexrgb(b)
    return "#%02X%02X%02X" % tuple(round(a[i] + (b[i] - a[i]) * k) for i in range(3))


def scale(c, k):
    return "#%02X%02X%02X" % tuple(min(255, round(v * k)) for v in render.hexrgb(c))


def palette(t):
    """The buddy's colours in theme t. The dying pose keeps the design's zombie colours in every theme."""
    accent = THEMES[t][2]
    if t == CREAM:   # the design (muscle.html)
        return dict(lines=["#B4C98A", "#9c917a", "#D2C09A", "#E2CFA4", "#EBD9AE", "#F7ECD3"], base="#1d1914",
                    liquid=accent, wet_line="#3a2f22", glow="#F3E2BC", spark="#F7ECD3", zzz="#C9B78F")
    # Outline by level as the design brightens it (resting dim .. target light); active is 0.9x as in the mock-ups
    lines = ["#B4C98A"] + [scale(accent, k) for k in (0.62, 0.82, 0.9, 1.0)] + [mix(accent, "#FFFFFF", 0.45)]
    return dict(lines=lines, base="#161616", liquid=accent, wet_line="#2B2B2B", glow=mix(accent, "#FFFFFF", 0.35),
                spark=lines[5], zzz=scale(accent, 0.86))


def theme_colours(t):
    """Face colours for theme t (BuffGen tables)."""
    key, _, accent, bottom = THEMES[t]
    if t == CREAM:
        return dict(accent=accent, right=["#F7ECD3", accent, bottom], left=["#FFFFFF", "#D3D3D3", "#A6A6A6"],
                    left_icon="#F2F2F2", left_value="#F2F2F2", aod_left="#7C7C7C", aod_right="#8A7D5E",
                    aod_minutes="#8A7D5E")
    return dict(accent=accent, right=[mix(accent, "#FFFFFF", 0.5), accent, bottom],
                left=["#9E9E9E", "#7F7F7F", "#5F5F5F"],
                left_icon="#C4C4C4", left_value="#FFFFFF", aod_left="#5A5A5A", aod_right=scale(accent, 0.6),
                aod_minutes="#B5B5B5")                             # white minutes: dim like the hours
AOD_LINE = 0.42                              # always-on buddy outline: its line colour at this brightness

STATE_LEVEL = [0, 1, 3, 4, 5]                # design level L for each state
STATE_NAMES = ["flatlining", "resting", "active", "intense", "insane"]


# ---- the design's renderVals(), ported ---------------------------------------------------------------------

def js(v):
    """A value as the design's template prints it."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def vals(L, sec, surface=None, t=CREAM):
    """Template values for design level L at second `sec` in theme t. `surface` overrides the fill line (figure
    units): above the figure = all wet, below = all dry."""
    pal = palette(t)
    odd = sec % 2 == 1
    bodyT = (("rotate(-4 100 160) translate(-1 4)" if odd else "rotate(4 100 160) translate(1 4)") if L == 0
             else "translate(0 -5)" if L == 5 and odd else "translate(0 0)")
    headT = ("rotate(17 100 76) translate(0 5)" if odd else "rotate(-17 100 76) translate(0 5)") if L == 0 \
        else "rotate(0 100 74)"
    punch = sec % 4 if L == 5 else 0
    sq = 1 if L in (3, 4) and odd else 0
    sx = {3: 0.86, 4: 1.0, 5: 1.15}.get(L, 1)
    as_ = {3: 0.8, 4: 1.0, 5: 1.2}.get(L, 1)
    armBulkT = (f"translate({(63 - 100) * (sx - 1):.2f} 0) translate(63 86) scale({js(float(as_))}) translate(-63 -86)"
                if L >= 3 else "translate(0 0)")
    torsoT = f"translate(100 0) scale({js(float(sx))} 1) translate(-100 0)" if L >= 3 else "translate(0 0)"
    raiseT = "rotate(-16 63 86)" if L == 5 and punch % 2 == 1 else "rotate(-8 63 86)"
    upperArm = (f"M66 78 C58 {71 - 3 * sq} 50 {67 - 4 * sq} 42 {68 - 3 * sq} C36 {69 - 3 * sq} 33 71 32 75 L29 77 "
                "C23 80 21 86 23 91 C27 96 36 99 48 99 C56 99 62 98 66 95 Z")
    curlT = "rotate(3 30 80)" if sq else "rotate(0 30 80)"
    if L == 5:
        armLines = ("M54 56 C58 62 62 66 66 74 M44 64 C47 62 50 60 54 58 M40 48 C42 44 43 40 44 36 M33.5 15 L33.5 21.5 "
                    "M39 14.5 L39 21.5 M45 14.5 L45 21.5 M29 21.5 L50 21.5 M30 27 C36 24.5 42 25 47.5 28 "
                    "M58 80 C60 86 61 92 60 96")
    elif L == 0:
        armLines = ("M68 84 C58 85 48 86 38 88 M68 92 C58 92 48 93 38 94 M31 100 L31.5 105 M34 101 L34.2 107 "
                    "M36.5 100 L36.3 104")
    elif L >= 2:
        armLines = (f"M66 80 C58 {73 - 3 * sq} 50 {69 - 4 * sq} 42 {70 - 3 * sq} C37 {71 - 3 * sq} 34 72 33 76 "
                    "M62 91 C52 89 40 87 31 82 M56 80 C60 84 62 90 61 96")
    else:
        armLines = ("M61 156 L61 162.5 M65 156.5 L65 163.5 M69 156 L69 162.5 M58.5 155.5 L73.5 155.5 "
                    "M60 150 C63 152 67 152 71 150.5 M70.5 86 C71.5 102 72 122 71 146 M61 118 C63 116 67 116 70 118")
    armLinesB = ("M38 49 L53 49 M33 75 C31 80 29 83 26 86 M45 30 L45 35 M50 30 L50 35 M55 31 L55 36 "
                 "M40 44 C45 42 51 42 56 44") if L in (3, 4) else ""
    base = ("M100 47 L99 56 Q100 57.5 101.5 56.5 M97.5 56 Q99 57.5 100 57 M102.5 56 Q101 57.5 100 57 "
            "M98 66 Q100 67 102 66 M90 56 Q92 60 95 63 M110 56 Q108 60 105 63")
    face = ("M100 47 L99 56 Q100 57.5 101.5 56.5 M90 56 Q92 60 95 63 M110 56 Q108 60 105 63" if L == 0 else
            base + " M90.5 45 L97 44.5 M103 44.5 L109.5 45 M92 48.5 Q94 47.6 96 48.5 M104 48.5 Q106 47.6 108 48.5 "
                   "M93.4 49.4 L94.6 49.4 M105.4 49.4 L106.6 49.4 M96 61.6 L104 61.6")
    # The design's fill line at progress p is 162 - 136p, with a 1.4-unit ripple; the watch clips flat.
    s = 200 if surface is None else surface
    pts = [(x, s) for x in range(-120, 321, 10)]
    wave = f"M-120 260 L-120 {s:.1f}" + "".join(f" L{x} {y:.2f}" for x, y in pts) + " L320 260 Z"
    dry = "M-120 -200 L320 -200 L" + " L".join(f"{x} {y:.2f}" for x, y in reversed(pts)) + " Z"
    skinny = L <= 1
    torso = ("M90 72 C84 75 76 76 70 80 C66 90 68 104 72 114 C76 128 80 144 84 160 L116 160 C120 144 124 128 128 114 "
             "C132 104 134 90 130 80 C124 76 116 75 110 72 Z" if skinny else
             "M88 72 C80 76 69 76 60 82 C55 92 57 104 62 112 C67 126 76 142 82 160 L118 160 C124 142 133 126 138 112 "
             "C143 104 145 92 140 82 C131 76 120 76 112 72 Z")
    neck = "M94 62 L106 62 L109 76 L91 76 Z" if skinny else "M91 62 L109 62 L114 76 L86 76 Z"
    torsoLines = ("M90 76 C84 78 78 79 72 81 M110 76 C116 78 122 79 128 81 M100 84 L100 114 M86 94 C82 96 78 99 75 103 "
                  "M86 102 C82 104 78 107 76 111 M87 110 C83 112 80 115 78 119 M114 94 C118 96 122 99 125 103 "
                  "M114 102 C118 104 122 107 124 111 M113 110 C117 112 120 115 122 119 M92 136 C96 140 104 140 108 136 "
                  "M100 140 L100 146" if skinny else
                  "M100 86 C92 100 78 102 68 94 M100 86 C108 100 122 102 132 94 M92 68 C86 72 78 74 70 77 "
                  "M108 68 C114 72 122 74 130 77 M100 104 L100 154 M89 114 C95 116 105 116 111 114 "
                  "M89 126 C95 128 105 128 111 126 M90 138 C95 140 105 140 110 138 M87 106 C84 124 85 142 90 156 "
                  "M113 106 C116 124 115 142 110 156 M74 108 L79 112 M75 116 L80 119 M77 124 L81 126 "
                  "M126 108 L121 112 M125 116 L120 119 M123 124 L119 126")
    lineC = pal["lines"][L]

    zstep = sec % 3
    zzz = [dict(x=120 + k * 7, y=40 - k * 9, s=9 + k * 3, o=1 if k == zstep else 0.45)
           for k in range(3) if k <= zstep] if L == 1 else []

    def drop_at(x, y, s_):
        return (f"M{x} {y} q{-3.2 * s_:.2f} {4.6 * s_:.2f} 0 {6.6 * s_:.2f} "
                f"q{3.2 * s_:.2f} {-2 * s_:.2f} 0 {-6.6 * s_:.2f} Z")
    seeds = [[118, 36, 1, 0], [82, 38, 0.9, 1], [121, 52, 0.8, 2], [79, 54, 0.75, 0], [30, 36, 0.8, 1],
             [170, 36, 0.8, 2], [104, 30, 0.7, 1], [58, 101, 0.95, 0], [48, 100, 0.8, 2], [38, 98, 0.7, 1],
             [142, 101, 0.95, 1], [152, 100, 0.8, 0], [162, 98, 0.7, 2]]
    drops = []
    if L == 4:
        for x, y, s_, ph in seeds:
            q = (sec + ph) % 3
            drops.append(dict(d=drop_at(x, y + q * (8 if y > 90 else 6), s_ * SWEAT_SCALE),
                              o=f"{0.95 - q * 0.25:.2f}"))

    def star(x, y, s_):
        return (f"M{x} {js(float(y - s_))} Q{x} {y} {js(float(x + s_))} {y} Q{x} {y} {x} {js(float(y + s_))} "
                f"Q{x} {y} {js(float(x - s_))} {y} Q{x} {y} {x} {js(float(y - s_))} Z")
    sparks = []
    if L == 5:
        for x, y, ph in [[14, 56, 0], [186, 58, 1], [70, 26, 2], [130, 24, 0], [16, 108, 1], [184, 104, 2],
                         [30, 146, 0], [170, 148, 1]]:
            q = (sec + ph) % 3
            sparks.append(dict(d=star(x, y, [6, 3.5, 1.5][q]), o=[1, 0.6, 0.25][q]))

    return dict(
        bodyT=bodyT, headT=headT, armLines=armLines, armLinesB=armLinesB, upperArm=upperArm, curlT=curlT,
        rightT="rotate(0 63 86)", rightFlex=True, rightPunch=False, rCurlT=curlT, rUpperArm=upperArm,
        rLinesA=armLines, rLinesB=armLinesB, burst="", flexArms=L in (3, 4), raisedArms=L == 5, raiseT=raiseT,
        burstT=armBulkT + " " + raiseT, armBulkT=armBulkT, torsoT=torsoT, downArms=L == 1, zombieArms=L == 0,
        zL="rotate(6 70 88)" if L == 0 else raiseT if L == 5 else "rotate(0)",
        zR="rotate(-9 70 88)" if L == 0 else raiseT if L == 5 else "rotate(0)",
        torso=torso, neck=neck, torsoLines=torsoLines, drops=drops, sparks=sparks, zzz=zzz,
        baseC="#243020" if L == 0 else pal["base"], wave=wave, lineC=lineC,
        liquidC="#6b665d" if L == 0 else pal["liquid"], figOp=(0.82 if odd else 1) if L == 0 else 1, dying=L == 0,
        figGlow="url(#mGlow)" if L == 5 else "none", dry=dry, face=face, rings=[], ariaLabel="")


def template():
    """The buddy's <svg> contents from the design, split at the overlays (drops / burst / sparks / zzz)."""
    t = open(DESIGN, encoding="utf-8").read()
    s = t.index('<svg width="208"')
    s = t.index(">", s) + 1
    e = t.index("</svg>", t.index('<sc-for list="{{zzz}}"'))
    inner = t[s:e]
    cut = inner.index('<sc-for list="{{drops}}"')
    return inner[:cut], inner[cut:]


def themed(tpl, t):
    """The template's fixed colours in theme t: the target glow, the lines on the fill, the sparkles."""
    pal = palette(t)
    for old, new in (('flood-color="#F3E2BC"', f'flood-color="{pal["glow"]}"'),
                     ('color="#3a2f22"', f'color="{pal["wet_line"]}"'),
                     ('fill="#F7ECD3"', f'fill="{pal["spark"]}"')):
        tpl = tpl.replace(old, new)
    return tpl


def expand(tpl, v):
    def for_rep(m):
        items, name, body = v[m.group(1)], m.group(2), m.group(3)
        return "".join(re.sub(r"\{\{" + name + r"\.(\w+)\}\}", lambda mm: js(it[mm.group(1)]), body) for it in items)
    tpl = re.sub(r'<sc-for list="\{\{(\w+)\}\}" as="(\w+)"[^>]*>(.*?)</sc-for>', for_rep, tpl, flags=re.S)
    inner_if = re.compile(r'<sc-if value="\{\{(\w+)\}\}"[^>]*>((?:(?!<sc-if\b).)*?)</sc-if>', re.S)
    while True:
        new = inner_if.sub(lambda m: m.group(2) if v[m.group(1)] else "", tpl)
        if new == tpl:
            break
        tpl = new
    return re.sub(r"\{\{(\w+)\}\}", lambda m: js(v[m.group(1)]), tpl)


def render_figure(inner):
    """Figure-unit SVG content -> 454x454 RGBA, placed where the design puts the buddy."""
    return render.render_svg(f'<g transform="translate({FX:.3f} {FY}) scale({FK:.6f}) translate(-16 -24)">{inner}</g>')


def screen_y(fig_y):
    return FY + (fig_y - 24) * FK


def zzz_overlay(L, sec, t=CREAM):
    """The resting zzz (SVG text in the design; rsvg can't use the embedded font, so drawn with Pillow)."""
    img = Image.new("RGBA", (454 * SS, 454 * SS), (0, 0, 0, 0))
    for z in vals(L, sec)["zzz"]:
        font = ImageFont.truetype(BOLD, round(z["s"] * FK * SS))
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        x = (FX + (z["x"] - 16) * FK) * SS
        ImageDraw.Draw(layer).text((x, screen_y(z["y"]) * SS), "z", font=font, anchor="ls",
                                   fill=render.hexrgb(palette(t)["zzz"]) + (round(255 * z["o"]),))
        img = Image.alpha_composite(img, layer)
    return img.resize((454, 454), Image.BOX)


def dim(hexc, k):
    return "#%02x%02x%02x" % tuple(round(c * k) for c in render.hexrgb(hexc))


def build_buddy():
    """Every theme's and state's images. Each image is written once: one that comes out the same in several themes
    (the dying pose, the sweat) is shared. Returns (ids, xy, files): ids[(t, s)] = {"d": [rid], "w": [...],
    "o": [...], "aod": rid}; xy[s] = the same shape with top-left corners, which are the same in every theme
    (checked); files = {rid: png}."""
    fig_tpl, ov_tpl = template()
    ids, xy, files, seen = {}, {}, {}, {}

    def save(img, t, s, name):
        img, x, y = render.crop_alpha(img)
        h = hashlib.sha1(img.tobytes() + repr(img.size).encode()).hexdigest()
        if h not in seen:
            rid, fn = f"Buddy{t}{s}{name}", f"buddy_{t}_{s}_{name.lower()}.png"
            img.save(os.path.join(OUT, fn))
            seen[h] = rid
            files[rid] = fn
        return seen[h], (x, y)

    for t in range(len(THEMES)):
        ft, ot = themed(fig_tpl, t), themed(ov_tpl, t)
        for s, L in enumerate(STATE_LEVEL):
            frames = 1 if L == 1 else 2
            entry, pos = {"d": [], "w": [], "o": []}, {"d": [], "w": [], "o": []}
            kinds = (["d"] if L != 5 else []) + (["w"] if L != 0 else [])
            for f in range(frames):
                for kind in kinds:
                    surface = 400 if kind == "d" else -200
                    rid, at = save(render_figure(expand(ft, vals(L, f, surface, t))), t, s, f"{kind.upper()}{f}")
                    entry[kind].append(rid)
                    pos[kind].append(at)
            if L in (1, 4, 5):   # overlays on a 3-second cycle, outside the body's transforms
                for k in range(3):
                    img = zzz_overlay(L, k, t) if L == 1 else render_figure(expand(ot, vals(L, k, None, t)))
                    rid, at = save(img, t, s, f"O{k}")
                    entry["o"].append(rid)
                    pos["o"].append(at)
            # Always-on: the silhouette's outline only (black body, no lines), dim; no glow
            v = vals(L, 0, 400, t)
            v.update(baseC="#000000", liquidC="#000000", lineC=dim(v["lineC"], AOD_LINE), figGlow="none", figOp=1,
                     dying=False, armLines="", armLinesB="", rLinesA="", rLinesB="", torsoLines="", face="")
            entry["aod"], pos["aod"] = save(render_figure(expand(ft, v)), t, s, "Aod")
            ids[(t, s)] = entry
            assert xy.setdefault(s, pos) == pos, f"theme {THEMES[t][0]}, state {s}: positions differ"
    for s, L in enumerate(STATE_LEVEL):
        print(f"  buddy {STATE_NAMES[s]:8s} L{L}: {len(xy[s]['d'])} dry, {len(xy[s]['w'])} wet, "
              f"{len(xy[s]['o'])} overlays")
    print(f"  {len(files)} buddy images for {len(THEMES)} themes")
    return ids, xy, files


def design_composite(L, sec, p):
    """The design's own picture of a state (figure + overlays), for checking against design/buff/*.png."""
    fig_tpl, ov_tpl = template()
    surface = 200 if L == 0 else (-60 if p >= 0.995 else 162 - p * 136)
    v = vals(L, sec, surface)
    img = render_figure(expand(fig_tpl, v) + (expand(ov_tpl, v) if L != 1 else ""))
    return Image.alpha_composite(img, zzz_overlay(L, sec)) if L == 1 else img


# ---- time digits ---------------------------------------------------------------------------------------------

TNUM = ["tnum"]   # the design sets font-variant-numeric: tabular-nums on the whole face


def build_digits():
    """Hours / minutes digit images (gradient glyph + its drop shadow, separately) and always-on
    outline digits, at TIME_PX (shadows scaled to match). The CSS: 66px Bold, letter-spacing -3; hours gradient #fff/#f2f2f2/#b4b4b4 with
    drop-shadow(0 4px 5px .95), minutes #F7ECD3/#D6C397 with drop-shadow(-4px 2px 4px .95); the gradients span the
    line box plus its 6px padding."""
    font = ImageFont.truetype(BOLD, TIME_PX * SS, layout_engine=ImageFont.Layout.RAQM)
    lh = TIME_PX * TIME_LH
    baseline = render.css_baseline(TIME_TOP, BOLD, TIME_PX, lh)
    g0, g1 = TIME_TOP - 6, TIME_TOP + lh + 6
    pad, cw, ch = 30, 110, 140
    origin = (pad, 100)                                 # pen (left, baseline) inside each canvas
    ys = np.arange(ch, dtype=np.float32) - origin[1] + baseline
    k = TIME_PX / 66                                    # the design's shadows, scaled with the digits
    styles = {"hour": ([(0, "#ffffff"), (0.5, "#f2f2f2"), (1, "#b4b4b4")], (0, round(4 * k), round(5 * k))),
              "min": ([(0, "#F7ECD3"), (1, "#D6C397")], (round(-4 * k), round(2 * k), round(4 * k)))}
    masks = {}
    for d in "0123456789":
        out = []
        for ring in (False, True):
            big = Image.new("L", (cw * SS, ch * SS), 0)
            draw = ImageDraw.Draw(big)
            if ring:
                draw.text((origin[0] * SS, origin[1] * SS), d, font=font, fill=0, anchor="ls", features=TNUM,
                          stroke_width=round(1.6 * SS), stroke_fill=255)
            else:
                draw.text((origin[0] * SS, origin[1] * SS), d, font=font, fill=255, anchor="ls", features=TNUM)
            out.append(np.asarray(big.resize((cw, ch), Image.BOX)).astype(np.float32) / 255.0)
        masks[d] = out
    offsets = {}
    for style, (stops, (dx, dy, blur)) in styles.items():
        grad = np.array([render.gradient_rgb(stops, (y - g0) / (g1 - g0)) for y in ys], dtype=np.float32)
        rgb = np.repeat(grad[:, None, :], cw, axis=1)
        offsets[style] = []
        for d in "0123456789":
            alpha = masks[d][0]
            glyph, gx, gy = render.crop_rel(render.to_rgba(rgb, alpha), origin)
            shad, sx, sy = render.crop_rel(render.to_rgba(np.zeros_like(rgb), render.shadow(alpha, dx, dy, blur, 0.95)), origin)
            glyph.save(os.path.join(OUT, f"t_{style}_{d}.png"))
            shad.save(os.path.join(OUT, f"t_{style}_{d}_sh.png"))
            offsets[style].append((gx, gy, sx, sy))
    offsets["aod"] = []
    white = np.full((ch, cw, 3), 255.0, np.float32)
    for d in "0123456789":
        fill, ring = masks[d]
        img, x, y = render.crop_rel(render.to_rgba(white, ring), origin)
        img.save(os.path.join(OUT, f"t_aod_{d}.png"))
        fimg, fx, fy = render.crop_rel(render.to_rgba(np.zeros_like(white), fill), origin)
        fimg.save(os.path.join(OUT, f"t_aodf_{d}.png"))
        offsets["aod"].append((x, y, fx, fy))
    adv = [round(font.getlength(d, features=TNUM) / SS) for d in "0123456789"]
    return offsets, adv, round(baseline)


# ---- icons -------------------------------------------------------------------------------------------------

def icon_id(name):
    return "Icon" + "".join(w.capitalize() for w in name.split("-"))


def build_icons():
    """The arcs' icons, one per metric (white: the watch tints them), and the streak's small gold flame (Lucide)."""
    def icon(name, box, stroke, color, out):
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{box}" height="{box}" viewBox="0 0 24 24" fill="none" '
               f'stroke="{color}" stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round">'
               f'{bmfont.ICON_SVG[name]}</svg>')
        render.run_rsvg(svg, os.path.join(OUT, out), box, box)
    for name in METRIC_ICONS:
        icon(name, ICON_PX, ICON_STROKE, "#FFFFFF", f"icon_{name.replace('-', '_')}.png")
    icon("flame", STREAK_ICON, 2.6, STREAK_GOLD, "icon_streak.png")


def build_launcher(ids, files):
    """The watch-face list icon: the cream buddy on target, on black."""
    img = Image.open(os.path.join(OUT, files[ids[(CREAM, 4)]["w"][0]]))
    img.thumbnail((61, 61), Image.LANCZOS)
    icon = Image.new("RGBA", (65, 65), (0, 0, 0, 255))
    icon.alpha_composite(img, ((65 - img.width) // 2, (65 - img.height) // 2))
    icon.save(os.path.join(ROOT, "resources", "drawables", "launcher_icon.png"))


# ---- fonts -------------------------------------------------------------------------------------------------

UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
DIGITS = "0123456789"
# id -> (font file, px, chars, tabular, tracking[, outline px]); tracking baked into the advances (one drawText).
# Digits are tabular everywhere, as in the design (font-variant-numeric: tabular-nums).
TEXT_FONTS = {
    "date": ("BarlowCondensed-SemiBold.ttf", DATE_PX, UPPER + DIGITS + " ", True, DATE_TRACK),
    "label": ("BarlowCondensed-Bold.woff2", LABEL_PX, UPPER + " ", False, LABEL_TRACK),
    "grams": ("BarlowCondensed-Bold.woff2", GRAMS_PX, DIGITS + "—", True, 0),
    "unit": ("BarlowCondensed-SemiBold.ttf", UNIT_PX, "g%", False, 0),
    "streak": ("BarlowCondensed-Bold.woff2", STREAK_PX, DIGITS + "-ADEKRSTY ", True, STREAK_TRACK),
    "stat": ("BarlowCondensed-Bold.woff2", STAT_PX, DIGITS + "K.+—%", True, 0),
    "stat_label": ("BarlowCondensed-SemiBold.ttf", STAT_LABEL_PX, UPPER + " ", False, STAT_LABEL_TRACK),
    "grams_ol": ("BarlowCondensed-Bold.woff2", GRAMS_PX, DIGITS + "—", True, 0, 1.5),
}


def build_fonts():
    os.makedirs(FONT_OUT, exist_ok=True)
    bmfont.OUT_DIR = FONT_OUT
    ascents = {fid: bmfont.text_font(fid, *spec) for fid, spec in TEXT_FONTS.items()}
    rows = ["<!-- GENERATED by tools/build_assets.py: Barlow Condensed (OFL) bitmap fonts. -->", "<fonts>"]
    for fid in TEXT_FONTS:
        rows.append(f'    <font id="{caps(fid)}" filename="{fid}.fnt" antialias="true"/>')
    rows.append("</fonts>")
    with open(os.path.join(FONT_OUT, "fonts.xml"), "w") as f:
        f.write("\n".join(rows) + "\n")
    return ascents


# ---- generated Monkey C ------------------------------------------------------------------------------------

def caps(s):
    return "".join(w.capitalize() for w in s.split("_"))


def mc_xy(pairs):
    return "[" + ", ".join(f"[{x}, {y}]" for x, y in pairs) + "]"


def write_gen(ids, xy, offsets, adv, time_base, ascents):
    L = {
        "DATE_BASE": render.css_baseline(DATE_TOP, SEMIBOLD, DATE_PX),
        "LABEL_BASE": render.css_baseline(LABEL_TOP, BOLD, LABEL_PX),
        "GRAMS_BASE": render.css_baseline(GRAMS_TOP, BOLD, GRAMS_PX),
    }
    fill_y0 = screen_y(162)               # fill line at progress 0 ...
    fill_dy = 136 * FK                    # ... rising this far at 100%
    lines = ["// GENERATED by tools/build_assets.py — do not edit.", "import Toybox.Lang;", "import Toybox.WatchUi;",
             "", "module BuffGen {"]
    consts = dict(ARC_R=ARC_R, ARC_W=ARC_W, TRACK_W=TRACK_W, ARC_SPAN=ARC_SPAN, LEFT_START=LEFT_START,
                  RIGHT_START=RIGHT_START, GRAD_TOP=GRAD_TOP, GRAD_BOT=GRAD_BOT, TIME_BASE=time_base,
                  TIME_TRACK=TIME_TRACK, STREAK_BASE=STREAK_BASE, STREAK_ICON=STREAK_ICON,
                  STREAK_ICON_TOP=STREAK_ICON_TOP, STREAK_GAP=STREAK_GAP, ICON_PX=ICON_PX,
                  STAT_CX_L=STAT_CX[0], STAT_CX_R=STAT_CX[1], STAT_NUM_BASE=STAT_NUM_BASE,
                  STAT_LABEL_BASE=STAT_LABEL_BASE, STAT_LABEL_TRACK=STAT_LABEL_TRACK,
                  DATE_TRACK=DATE_TRACK, LABEL_TRACK=LABEL_TRACK,
                  FILL_Y0=f"{fill_y0:.1f}", FILL_DY=f"{fill_dy:.1f}")
    consts.update({k: round(v) for k, v in L.items()})
    for k, v in consts.items():
        lines.append(f"    const {k} = {v};")
    for k, v in ascents.items():
        lines.append(f"    const ASCENT_{k.upper()} = {v};")
    lines.append("    const ICON_LEFT = [%d, %d] as Array<Number>;" % ICONS["left"])
    lines.append("    const ICON_RIGHT = [%d, %d] as Array<Number>;" % ICONS["right"])
    lines.append("    const TIME_ADV = [" + ", ".join(map(str, adv)) + "] as Array<Number>;   // digit advances, px")
    for style in ("hour", "min", "aod"):
        lines.append(f"    const OFF_{style.upper()} = [" + ", ".join("[" + ", ".join(map(str, r)) + "]"
                                                             for r in offsets[style])
                     + "] as Array<Array<Number>>;   // glyph x,y + shadow (or fill) x,y from pen x / baseline")
    for style in ("hour", "min"):
        lines.append(f"    function glyphs{caps(style)}() as Array<ResourceId> {{ return ["
                     + ", ".join(f"Rez.Drawables.T{caps(style)}{d}" for d in range(10)) + "]; }")
        lines.append(f"    function shadows{caps(style)}() as Array<ResourceId> {{ return ["
                     + ", ".join(f"Rez.Drawables.T{caps(style)}{d}Sh" for d in range(10)) + "]; }")
    lines.append("    function aodGlyphs() as Array<ResourceId> { return ["
                 + ", ".join(f"Rez.Drawables.TAod{d}" for d in range(10)) + "]; }")
    lines.append("    function aodFills() as Array<ResourceId> { return ["
                 + ", ".join(f"Rez.Drawables.TAodf{d}" for d in range(10)) + "]; }")
    # Buddy tables: positions per state, images per theme and state
    n = len(THEMES)
    lines.append("    // Buddy, per state (dying, resting, active, intense, target): top-left corners (every theme's the same)")
    for kind, name in (("d", "Dry"), ("w", "Wet"), ("o", "Over")):
        lines.append(f"    const {name.upper()}_XY = [" + ", ".join(mc_xy(xy[s][kind]) for s in range(5))
                     + "] as Array<Array<Array<Number>>>;")
        lines.append(f"    function {name.lower()}(t as Number, s as Number) as Array<ResourceId> {{ return [" + ", ".join(
            "[" + ", ".join("[" + ", ".join(f"Rez.Drawables.{r}" for r in ids[(t, s)][kind]) + "]" for s in range(5))
            + "]" for t in range(n)) + "][t][s] as Array<ResourceId>; }")
    lines.append("    const AOD_XY = " + mc_xy([xy[s]["aod"] for s in range(5)]) + " as Array<Array<Number>>;")
    lines.append("    function aod(t as Number, s as Number) as ResourceId { return [" + ", ".join(
        "[" + ", ".join(f"Rez.Drawables.{ids[(t, s)]['aod']}" for s in range(5)) + "]" for t in range(n))
        + "][t][s] as ResourceId; }")
    # Colour themes (THEMES): style id - 1
    tc = [theme_colours(t) for t in range(n)]
    col = lambda c: "0x" + c.lstrip("#").upper()
    lines.append("    // Colour themes, in the watch-face editor's order (resources/configs/watchface.xml): "
                 + ", ".join(th[1] for th in THEMES))
    lines.append(f"    const THEME_COUNT = {n};")
    lines.append(f"    const DEFAULT_THEME = {CREAM};   // {THEMES[CREAM][1]}")
    for key, name in (("accent", "ACCENT"), ("left_icon", "LEFT_ICON"), ("left_value", "LEFT_VALUE"),
                      ("aod_left", "AOD_LEFT"), ("aod_right", "AOD_RIGHT"), ("aod_minutes", "AOD_MINUTES")):
        lines.append(f"    const {name} = [" + ", ".join(col(c[key]) for c in tc) + "] as Array<Number>;")
    for key, name in (("right", "RIGHT_GRAD"), ("left", "LEFT_GRAD")):
        lines.append(f"    const {name} = [" + ", ".join("[" + ", ".join(col(x) for x in c[key]) + "]" for c in tc)
                     + "] as Array<Array<Number>>;   // top, middle, bottom of the screen")
    lines.append("    const CREAM_MINUTES = [" + ", ".join("true" if t == CREAM else "false" for t in range(n))
                 + "] as Array<Boolean>;   // else white minutes (the hours' images)")
    lines.append("}")
    with open(os.path.join(GEN, "BuffGen.mc"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return consts


def write_drawables(files):
    rows = ["<drawables>", "    <!-- GENERATED by tools/build_assets.py -->"]
    def bm(rid, fn):
        rows.append(f'    <bitmap id="{rid}" filename="{fn}" packingFormat="png"/>')
    for style in ("hour", "min"):
        for d in range(10):
            bm(f"T{caps(style)}{d}", f"t_{style}_{d}.png")
            bm(f"T{caps(style)}{d}Sh", f"t_{style}_{d}_sh.png")
    for d in range(10):
        bm(f"TAod{d}", f"t_aod_{d}.png")
        bm(f"TAodf{d}", f"t_aodf_{d}.png")
    for rid, fn in files.items():
        bm(rid, fn)
    for name in METRIC_ICONS:
        bm(icon_id(name), f"icon_{name.replace('-', '_')}.png")
    bm("IconStreak", "icon_streak.png")
    rows.append("</drawables>")
    with open(os.path.join(OUT, "drawables.xml"), "w") as f:
        f.write("\n".join(rows) + "\n")


def main():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(GEN, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith(".png"):
            os.unlink(os.path.join(OUT, f))
    ids, xy, files = build_buddy()
    offsets, adv, time_base = build_digits()
    build_icons()
    build_launcher(ids, files)
    ascents = build_fonts()
    consts = write_gen(ids, xy, offsets, adv, time_base, ascents)
    write_drawables(files)
    print("time advances", adv, "baseline", time_base)
    print("layout:", {k: v for k, v in consts.items() if k.endswith("_BASE") or k.startswith("FILL")})


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--check":
        # Design composites of each state as the design's PNGs show them, for comparing (scratch output path)
        out = sys.argv[2]
        os.makedirs(out, exist_ok=True)
        for name, L, deficit in (("dying", 0, 40), ("resting", 1, 180), ("active", 3, 423), ("intense", 4, 900),
                                 ("target", 5, 1600)):
            for sec in (0, 1):
                design_composite(L, sec, min(deficit / 1540, 1)).save(os.path.join(out, f"design_{name}_{sec}.png"))
        print("wrote design composites to", out)
    else:
        main()
