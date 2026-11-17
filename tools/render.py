"""Rendering helpers for tools/build_assets.py: SVG -> PNG (rsvg-convert), CSS-like text metrics, drop shadows."""
import os
import subprocess
import tempfile

import numpy as np
from PIL import Image, ImageFilter, ImageFont

FONTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts")
W = H = 454   # the screen (fēnix 8 47/51 mm)


def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def css_metrics(path, size):
    """(ascent, descent) in px the way a browser lays out a line box (hhea metrics, unrounded)."""
    asc, desc = ImageFont.truetype(path, 1000).getmetrics()
    return asc * size / 1000.0, desc * size / 1000.0


def css_baseline(line_top, path, size, line_height=None):
    """Baseline y of a CSS line box: top + half-leading + ascent."""
    lh = size if line_height is None else line_height
    a, d = css_metrics(path, size)
    return line_top + (lh - (a + d)) / 2.0 + a


def run_rsvg(svg, out_png, w=W, h=H):
    conf = tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False)
    conf.write(f'<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "fonts.dtd"><fontconfig>'
               f'<dir>{FONTS}</dir><cachedir>{tempfile.gettempdir()}/buff-fc-cache</cachedir></fontconfig>')
    conf.close()
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg)
    subprocess.run(["rsvg-convert", "-w", str(w), "-h", str(h), f.name, "-o", out_png], check=True,
                   env={**os.environ, "FONTCONFIG_FILE": conf.name})
    os.unlink(f.name)
    os.unlink(conf.name)


def render_svg(body, w=W, h=H):
    """SVG body (screen coordinates) -> RGBA image of the whole screen."""
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        tmp = f.name
    run_rsvg(f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{body}</svg>',
             tmp, w, h)
    img = Image.open(tmp).convert("RGBA")
    os.unlink(tmp)
    return img


def crop_alpha(img, threshold=2):
    """Crop an RGBA image to its visible pixels. Returns (image, left, top)."""
    box = img.getchannel("A").point(lambda v: 255 if v >= threshold else 0).getbbox()
    return img.crop(box), box[0], box[1]


def crop_rel(img, origin):
    """Crop to visible pixels; offsets relative to the pen origin (x) and the baseline (y)."""
    cropped, x, y = crop_alpha(img, 3)
    return cropped, round(x - origin[0]), round(y - origin[1])


def shadow(alpha, dx, dy, blur_css, opacity):
    """CSS drop-shadow(dx dy blur) of an alpha mask: offset, Gaussian sigma = blur/2, scaled by opacity."""
    a = Image.fromarray((alpha * 255).astype(np.uint8))
    a = a.transform(a.size, Image.AFFINE, (1, 0, -dx, 0, 1, -dy), resample=Image.BILINEAR)
    a = a.filter(ImageFilter.GaussianBlur(blur_css / 2.0))
    return np.asarray(a).astype(np.float32) / 255.0 * opacity


def to_rgba(rgb, alpha):
    a8 = (np.clip(alpha, 0, 1) * 255).round().astype(np.uint8)
    return Image.fromarray(np.dstack([np.clip(rgb, 0, 255).astype(np.uint8), a8]), "RGBA")


def gradient_rgb(stops, t):
    t = min(max(t, 0.0), 1.0)
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        if t <= p1:
            k = 0.0 if p1 == p0 else (t - p0) / (p1 - p0)
            a, b = hexrgb(c0), hexrgb(c1)
            return tuple(a[i] + (b[i] - a[i]) * k for i in range(3))
    return hexrgb(stops[-1][1])
