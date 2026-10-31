#!/usr/bin/env python3
"""
Clues & Curses (C&C) - Logo pixel-art della schermata iniziale, generato via codice.

Font: Jacquard 24 (blackletter pixel, SIL OFL 1.1) per "Clues & Curses",
      Pixelify Sans (SIL OFL 1.1) per il sottotitolo.
Solo colori della palette del gioco. Il logo viene prodotto alla risoluzione "logica"
(1 pixel = 1 pixel di gioco a 360x640) e in Godot si ingrandisce x2 con filtro Nearest.

Uso:  python3 make_logo.py <cartella_font> <cartella_uscita>
Produce: logo_cc.png, logo_subtitle.png, logo_preview.png (x4 su sfondo)
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

TITLE = "Clues & Curses"
SUBTITLE = "INDAGINI · ENIGMI · MALEDIZIONI"
MAX_WIDTH = 340          # il logo deve stare nei 360 px di larghezza del gioco

P = {
    "n0": (11, 10, 18), "a0": (58, 29, 74), "a1": (107, 47, 122), "a2": (160, 80, 176),
    "w2": (74, 46, 33), "f0": (194, 128, 58), "f1": (219, 160, 74), "f2": (240, 192, 96),
    "f3": (255, 224, 138), "f4": (255, 244, 204), "b1": (107, 18, 25), "b2": (156, 29, 34),
    "n6": (86, 96, 126), "n7": (122, 131, 160),
}


def text_mask(text, font_path, size, pad=4):
    """Testo binario (niente anti-aliasing) ritagliato, con margine per contorno e ombra."""
    font = ImageFont.truetype(str(font_path), size)
    l, t, r, b = font.getbbox(text)
    im = Image.new("L", (r - l + pad * 2, b - t + pad * 2), 0)
    d = ImageDraw.Draw(im)
    d.fontmode = "1"
    d.text((pad - l, pad - t), text, font=font, fill=255)
    return np.asarray(im) > 127


def dilate(m, n=1):
    out = m.copy()
    for _ in range(n):
        o = out.copy()
        o[1:] |= out[:-1]; o[:-1] |= out[1:]
        o[:, 1:] |= out[:, :-1]; o[:, :-1] |= out[:, 1:]
        out = o
    return out


def title_mask(font_dir):
    """Il titolo alla dimensione più grande (multipla di 8, per restare nitido) che sta in MAX_WIDTH."""
    for size in (48, 40, 32, 24):
        m = text_mask(TITLE, font_dir / "Jacquard24.ttf", size, pad=6)
        if m.shape[1] <= MAX_WIDTH:
            return m
    return m


def logo(font_dir):
    m = title_mask(font_dir)
    h, w = m.shape
    ys, xs = np.nonzero(m)
    top, bot = ys.min(), ys.max()

    img = np.zeros((h, w, 4), np.uint8)

    def put(mask, color):
        img[mask] = (*P[color], 255)

    # 1) ombra arcana spostata in basso a destra (2 px), 2) contorno scuro 1 px
    shadow = np.zeros_like(m)
    shadow[2:, 2:] = dilate(m)[:-2, :-2]
    put(shadow & ~dilate(m), "a0")
    put(dilate(m) & ~m, "n0")

    # 3) riempimento oro a bande orizzontali (luce di candela dal basso: piu' chiaro in basso)
    bands = ["f0", "f1", "f2", "f2", "f3", "f3"]
    for y in range(top, bot + 1):
        t = (y - top) / max(1, bot - top)
        row = m[y]
        img[y][row] = (*P[bands[min(len(bands) - 1, int(t * len(bands)))]], 255)

    # 4) bordo superiore di ogni tratto: ombra fredda (luce dal basso, ombre blu-viola)
    upper = m & ~np.vstack([np.zeros((1, w), bool), m[:-1]])
    img[upper & m] = (*P["w2"], 255)
    # 5) riflesso chiaro sul bordo inferiore dei tratti
    lower = m & ~np.vstack([m[1:], np.zeros((1, w), bool)])
    img[lower] = (*P["f4"], 255)

    return Image.fromarray(img, "RGBA")


def subtitle(font_dir):
    m = text_mask(SUBTITLE, font_dir / "PixelifySans-Regular.ttf", 12, pad=2)
    img = np.zeros((*m.shape, 4), np.uint8)
    img[dilate(m) & ~m] = (*P["n0"], 255)
    img[m] = (*P["n7"], 255)
    return Image.fromarray(img, "RGBA")


def ornament(width):
    """Filetto con rombo centrale (runa stilizzata) sotto il titolo."""
    h = 7
    img = Image.new("RGBA", (width, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cy, cx = h // 2, width // 2
    d.line([(4, cy), (cx - 6, cy)], fill=(*P["a1"], 255))
    d.line([(cx + 6, cy), (width - 5, cy)], fill=(*P["a1"], 255))
    d.polygon([(cx, 0), (cx + 3, cy), (cx, h - 1), (cx - 3, cy)], fill=(*P["a2"], 255), outline=(*P["n0"], 255))
    for x in (4, width - 5):
        d.point((x, cy), fill=(*P["a2"], 255))
    return img


def main():
    font_dir, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    lg = logo(font_dir)
    orn = ornament(lg.width - 20)
    sub = subtitle(font_dir)

    width = max(lg.width, sub.width)
    full = Image.new("RGBA", (width, lg.height + orn.height + sub.height + 4), (0, 0, 0, 0))
    full.alpha_composite(lg, ((width - lg.width) // 2, 0))
    full.alpha_composite(orn, ((width - orn.width) // 2, lg.height - 2))
    full.alpha_composite(sub, ((width - sub.width) // 2, lg.height + orn.height + 2))
    full.save(out / "logo_cc.png")
    sub.save(out / "logo_subtitle.png")

    prev = Image.new("RGBA", (full.width + 40, full.height + 40), (*P["n0"], 255))
    prev.alpha_composite(full, (20, 20))
    prev.resize((prev.width * 4, prev.height * 4), Image.NEAREST).save(out / "logo_preview.png")
    print("logo", full.size)


if __name__ == "__main__":
    main()
