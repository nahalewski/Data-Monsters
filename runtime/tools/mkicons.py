#!/usr/bin/env python3
"""
Generate the XMB assets for the EBOOT without any image library:
    ICON0.PNG  144x80   game icon
    PIC1.PNG   480x272  background shown when the icon is selected
Text is drawn with the public-domain font8x8 glyphs the runtime also uses.

    mkicons.py OUT_DIR
"""
import os
import re
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_H = os.path.join(HERE, "..", "..", "third_party", "font8x8", "font8x8_basic.h")


def load_font():
    text = open(FONT_H).read()
    body = text[text.index("{", text.index("font8x8_basic")):]
    rows = re.findall(r"\{([^{}]*)\}", body)
    glyphs = []
    for r in rows:
        vals = [int(v, 0) for v in re.findall(r"0x[0-9A-Fa-f]+", r)]
        if len(vals) == 8:
            glyphs.append(vals)
    return glyphs


def png(path, w, h, px):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw += bytes(px[y * w + x])

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(chunk(b"IEND", b""))


def canvas(w, h, top, bottom):
    px = []
    for y in range(h):
        t = y / max(1, h - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        px += [c] * w
    return px


def rect(px, w, x0, y0, rw, rh, c):
    for y in range(y0, y0 + rh):
        for x in range(x0, x0 + rw):
            if 0 <= x < w and y * w + x < len(px):
                px[y * w + x] = c


def text(px, w, glyphs, s, x0, y0, scale, c):
    for i, ch in enumerate(s):
        g = glyphs[ord(ch)] if ord(ch) < len(glyphs) else glyphs[ord("?")]
        for ry in range(8):
            for rx in range(8):
                if g[ry] & (1 << rx):
                    rect(px, w, x0 + (i * 8 + rx) * scale, y0 + ry * scale, scale, scale, c)


def cartridge(px, w, x, y, s, body, label):
    # a little Game Boy cartridge silhouette
    rect(px, w, x, y + 2 * s, 14 * s, 18 * s, body)
    rect(px, w, x + 1 * s, y, 12 * s, 2 * s, body)
    rect(px, w, x + 2 * s, y + 5 * s, 10 * s, 8 * s, label)
    rect(px, w, x + 3 * s, y + 15 * s, 8 * s, 1 * s, label)


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    glyphs = load_font()
    red, dark, cream = (200, 40, 50, 255), (30, 20, 40, 255), (240, 232, 214, 255)

    w, h = 144, 80
    px = canvas(w, h, (60, 24, 40), (24, 12, 30))
    rect(px, w, 0, 0, w, 3, red)
    cartridge(px, w, 12, 20, 2, red, cream)
    text(px, w, glyphs, "GEN 1", 52, 22, 2, cream)
    text(px, w, glyphs, "PORT", 52, 42, 2, cream)
    text(px, w, glyphs, "for PSP", 52, 62, 1, (200, 190, 200, 255))
    png(os.path.join(out, "ICON0.PNG"), w, h, px)

    w, h = 480, 272
    px = canvas(w, h, (44, 18, 34), (12, 8, 20))
    rect(px, w, 0, 0, w, 6, red)
    cartridge(px, w, 40, 70, 5, red, cream)
    text(px, w, glyphs, "GEN 1 PORT", 140, 84, 4, cream)
    text(px, w, glyphs, "for PSP", 140, 124, 3, (210, 200, 210, 255))
    grey, dim = (170, 160, 175, 255), (140, 130, 150, 255)
    text(px, w, glyphs, "Based on the Pokemon Gen 1 Recompilation Project", 24, 206, 1, grey)
    text(px, w, glyphs, "by BOIS CLUB GAMES, LLC", 24, 218, 1, grey)
    text(px, w, glyphs, "github.com/bryanthaboi/gen1recomp", 24, 230, 1, grey)
    text(px, w, glyphs, "Bring your own cartridge dump: roms/", 24, 242, 1, dim)
    text(px, w, glyphs, "Ported by nahalewski", 24, 256, 1, (220, 200, 150, 255))
    png(os.path.join(out, "PIC1.PNG"), w, h, px)

    # PS Vita LiveArea: icon0 128x128, bg 840x500, startup 280x158
    vita = os.path.join(out, "vita")
    os.makedirs(vita, exist_ok=True)
    w, h = 128, 128
    px = canvas(w, h, (60, 24, 40), (24, 12, 30))
    cartridge(px, w, 18, 20, 2, red, cream)
    text(px, w, glyphs, "GEN 1", 56, 34, 2, cream)
    text(px, w, glyphs, "PORT", 56, 54, 2, cream)
    text(px, w, glyphs, "Vita", 56, 76, 1, (200, 190, 200, 255))
    png(os.path.join(vita, "icon0.png"), w, h, px)
    w, h = 840, 500
    px = canvas(w, h, (44, 18, 34), (12, 8, 20))
    rect(px, w, 0, 0, w, 8, red)
    cartridge(px, w, 60, 120, 8, red, cream)
    text(px, w, glyphs, "GEN 1 PORT", 220, 150, 6, cream)
    text(px, w, glyphs, "for PS Vita", 220, 210, 4, (210, 200, 210, 255))
    text(px, w, glyphs, "Based on the Pokemon Gen 1 Recompilation Project", 40, 400, 2, grey)
    text(px, w, glyphs, "by BOIS CLUB GAMES, LLC - github.com/bryanthaboi/gen1recomp", 40, 424, 2, grey)
    text(px, w, glyphs, "Ported by nahalewski", 40, 456, 2, (220, 200, 150, 255))
    png(os.path.join(vita, "bg.png"), w, h, px)
    w, h = 280, 158
    px = canvas(w, h, (60, 24, 40), (24, 12, 30))
    cartridge(px, w, 20, 30, 4, red, cream)
    text(px, w, glyphs, "GEN 1 PORT", 100, 50, 2, cream)
    text(px, w, glyphs, "for PS Vita", 100, 76, 1, (210, 200, 210, 255))
    png(os.path.join(vita, "startup.png"), w, h, px)

    # PS3 XMB icon 320x176
    ps3 = os.path.join(out, "ps3")
    os.makedirs(ps3, exist_ok=True)
    w, h = 320, 176
    px = canvas(w, h, (60, 24, 40), (24, 12, 30))
    rect(px, w, 0, 0, w, 5, red)
    cartridge(px, w, 24, 40, 4, red, cream)
    text(px, w, glyphs, "GEN 1 PORT", 110, 60, 3, cream)
    text(px, w, glyphs, "for PS3", 110, 96, 2, (210, 200, 210, 255))
    text(px, w, glyphs, "Ported by nahalewski", 110, 130, 1, (220, 200, 150, 255))
    png(os.path.join(ps3, "ICON0.PNG"), w, h, px)
    print("wrote", out)


if __name__ == "__main__":
    main()
