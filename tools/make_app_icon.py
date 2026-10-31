#!/usr/bin/env python3
"""
Clues & Curses - Icona dell'app (scheda del browser, schermata Home, PWA), disegnata via codice.
Una runa Othala accesa dentro un cerchio arcano, su fondo notte. Pixel art 32x32
ingrandita a multipli interi; il resto del riquadro è fondo (va bene come icona "maskable").

Uso:  python3 make_app_icon.py <cartella_uscita>
Produce: app_icon_512.png, app_icon_180.png, app_icon_144.png, app_icon_256.png (icona del progetto)
"""
import sys
from pathlib import Path
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_tiles import P, RUNES  # noqa: E402

N = 32


def rgb(key):
    h = P[key].lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) + (255,)


def base():
    img = Image.new("RGBA", (N, N), rgb("n0"))
    px = img.load()
    c = (N - 1) / 2
    for y in range(N):
        for x in range(N):
            d = ((x - c) ** 2 + (y - c) ** 2) ** 0.5
            if d < 12.5:
                px[x, y] = rgb("n1")
            if 12.5 <= d < 13.6:
                px[x, y] = rgb("a1")
            if 13.6 <= d < 14.6:
                px[x, y] = rgb("a0")
    for x, y in ((15, 2), (16, 2), (2, 15), (2, 16), (29, 15), (29, 16), (15, 29), (16, 29)):
        px[x, y] = rgb("a2")      # quattro rune-punto sul cerchio
    rows = RUNES["othala"]
    for y, row in enumerate(rows):          # la runa a 1x, centrata, con ombra
        for x, ch in enumerate(row):
            if ch == "#":
                px[x + 8 + 1, y + 9 + 1] = rgb("w2")
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch == "#":
                px[x + 8, y + 9] = rgb("f2") if y > 8 else rgb("f3")
    return img


def fit(img, size):
    k = size // N
    big = img.resize((N * k, N * k), Image.NEAREST)
    out = Image.new("RGBA", (size, size), rgb("n0"))
    out.alpha_composite(big, ((size - big.width) // 2, (size - big.height) // 2))
    return out


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "out")
    out.mkdir(parents=True, exist_ok=True)
    img = base()
    for s in (512, 256, 180, 144):
        fit(img, s).save(out / f"app_icon_{s}.png")
    print("icone in", out)


if __name__ == "__main__":
    main()
