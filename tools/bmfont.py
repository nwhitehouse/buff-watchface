"""Bitmap fonts for Connect IQ (BMFont .fnt + .png) rendered from Barlow Condensed, and the Lucide icons
(https://lucide.dev, ISC licence) used by the face."""
import os

from PIL import Image, ImageDraw, ImageFont

FONT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts")
OUT_DIR = None        # set by build_assets.py
SUPERSAMPLE = 4       # render at 4x and box-downscale: unhinted outlines, close to how a browser renders the design

# Lucide icon contents (24x24 viewBox, stroke drawn by the caller), lucide-static 0.460.0
ICON_SVG = {
    "activity": '<path d="M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2"/>',
    "battery-charging": '<path d="M15 7h1a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2h-2"/> <path d="M6 7H4a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h1"/> <path d="m11 7-3 5h4l-3 5"/> <line x1="22" x2="22" y1="11" y2="13"/>',
    "battery-medium": '<rect width="16" height="10" x="2" y="7" rx="2" ry="2"/> <line x1="22" x2="22" y1="11" y2="13"/> <line x1="6" x2="6" y1="11" y2="13"/> <line x1="10" x2="10" y1="11" y2="13"/>',
    "chevrons-up": '<path d="m17 11-5-5-5 5"/> <path d="m17 18-5-5-5 5"/>',
    "droplet": '<path d="M12 22a7 7 0 0 0 7-7c0-2-1-3.9-3-5.5s-3.5-4-4-6.5c-.5 2.5-2 4.9-4 6.5C6 11.1 5 13 5 15a7 7 0 0 0 7 7z"/>',
    "flame": '<path d="M8.5 14.5A2.5 2.5 0 0 0 11 12c0-1.38-.5-2-1-3-1.072-2.143-.224-4.054 2-6 .5 2.5 2 4.9 4 6.5 2 1.6 3 3.5 3 5.5a7 7 0 1 1-14 0c0-1.153.433-2.294 1-3a2.5 2.5 0 0 0 2.5 2.5z"/>',
    "footprints": '<path d="M4 16v-2.38C4 11.5 2.97 10.5 3 8c.03-2.72 1.49-6 4.5-6C9.37 2 10 3.8 10 5.5c0 3.11-2 5.66-2 8.68V16a2 2 0 1 1-4 0Z"/> <path d="M20 20v-2.38c0-2.12 1.03-3.12 1-5.62-.03-2.72-1.49-6-4.5-6C14.63 6 14 7.8 14 9.5c0 3.11 2 5.66 2 8.68V20a2 2 0 1 0 4 0Z"/> <path d="M16 17h4"/> <path d="M4 13h4"/>',
    "heart": '<path d="M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z"/>',
    "hourglass": '<path d="M5 22h14"/> <path d="M5 2h14"/> <path d="M17 22v-4.172a2 2 0 0 0-.586-1.414L12 12l-4.414 4.414A2 2 0 0 0 7 17.828V22"/> <path d="M7 2v4.172a2 2 0 0 0 .586 1.414L12 12l4.414-4.414A2 2 0 0 0 17 6.172V2"/>',
    "moon": '<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>',
    "zap": '<path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z"/>',
}


def pack(glyphs, page_w):
    """Shelf-pack glyph images; returns (page_h, positions)."""
    x = y = shelf_h = 0
    pos = {}
    for ch, g in glyphs.items():
        w, h = g["img"].size
        if x + w + 1 > page_w:
            x, y, shelf_h = 0, y + shelf_h + 1, 0
        pos[ch] = (x, y)
        x += w + 1
        shelf_h = max(shelf_h, h)
    return y + shelf_h, pos


def write_bmfont(font_id, face, size, glyphs, ascent, line_height):
    page_w = 256 if size < 60 else 512
    page_h, pos = pack(glyphs, page_w)
    page = Image.new("RGBA", (page_w, max(page_h, 1)), (255, 255, 255, 0))
    for ch, g in glyphs.items():
        alpha = g["img"]
        # Coverage in every channel (white glyph, premultiplied): the Connect IQ font compiler reads anti-aliasing
        # levels from the colour channels, not only alpha.
        page.paste(Image.merge("RGBA", (alpha, alpha, alpha, alpha)), pos[ch])
    png_name = f"{font_id}.png"
    page.save(os.path.join(OUT_DIR, png_name))
    lines = [
        f'info face="{face}" size={size} bold=0 italic=0 charset="" unicode=1 stretchH=100 smooth=1 aa=1 padding=0,0,0,0 spacing=1,1',
        f"common lineHeight={line_height} base={ascent} scaleW={page_w} scaleH={page.size[1]} pages=1 packed=0",
        f'page id=0 file="{png_name}"',
        f"chars count={len(glyphs)}",
    ]
    for ch, g in glyphs.items():
        x, y = pos[ch]
        w, h = g["img"].size
        lines.append(f"char id={ord(ch)} x={x} y={y} width={w} height={h} xoffset={g['xoff']} "
                     f"yoffset={g['yoff']} xadvance={g['adv']} page=0 chnl=15")
    with open(os.path.join(OUT_DIR, f"{font_id}.fnt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return page.size


def text_font(font_id, ttf, size, chars, tabular=False, track=0, outline=None):
    """One bitmap font: each glyph rendered at 4x and downscaled; letter-spacing (`track`) baked into the advances;
    `outline` px renders a ring just outside each glyph instead (always-on). Returns the font's ascent."""
    ss = SUPERSAMPLE
    font = ImageFont.truetype(os.path.join(FONT_DIR, ttf), size * ss, layout_engine=ImageFont.Layout.RAQM)
    feats = ["tnum"] if tabular else None
    ox, oy = size, size * 2  # pen origin (left, baseline) in output pixels
    rendered = {}
    for ch in chars:
        big = Image.new("L", (size * 3 * ss, size * 3 * ss), 0)
        if outline:
            ImageDraw.Draw(big).text((ox * ss, oy * ss), ch, font=font, fill=0, anchor="ls", features=feats,
                                     stroke_width=max(1, round(outline * ss)), stroke_fill=255)
        else:
            ImageDraw.Draw(big).text((ox * ss, oy * ss), ch, font=font, fill=255, anchor="ls", features=feats)
        canvas = big.resize((size * 3, size * 3), Image.BOX)
        rendered[ch] = (canvas, canvas.getbbox())
    inks = [ink for _, ink in rendered.values() if ink]
    ascent = max(oy - ink[1] for ink in inks)
    descent = max(max(ink[3] - oy for ink in inks), 0)
    glyphs = {}
    for ch in chars:
        canvas, ink = rendered[ch]
        adv = int(round(font.getlength(ch, features=feats) / ss)) + track
        if not ink:  # blank glyph (space)
            glyphs[ch] = {"img": Image.new("L", (1, 1), 0), "xoff": 0, "yoff": 0, "adv": adv}
            continue
        glyphs[ch] = {"img": canvas.crop(ink), "xoff": ink[0] - ox, "yoff": ascent - (oy - ink[1]), "adv": adv}
    face = ttf.replace(".ttf", "").replace(".woff2", "")
    page = write_bmfont(font_id, face, size, glyphs, ascent, ascent + descent)
    print(f"  {font_id:10s} {face} {size}px  ascent={ascent} chars={len(chars)} page={page}")
    return ascent
