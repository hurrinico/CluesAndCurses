#!/usr/bin/env python3
"""
Clues & Curses - Sfondo della schermata iniziale (360x640), disegnato via codice in pixel art.

Oakhaven di notte vista dai tetti: cielo a bande con dithering, luna velata,
nuvole, guglia della cattedrale, tetti e camini con finestre accese,
cornicione in primo piano con rune viola. Solo colori della palette del gioco.
Pioggia e bagliori NON sono nell'immagine: li anima la scena di Godot.

Uso:  python3 make_title_bg.py <cartella_uscita> [seed]
"""
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw

W, H = 360, 640
C = {
    "n0": (11, 10, 18), "n1": (20, 18, 31), "n2": (28, 27, 46), "n3": (38, 38, 64),
    "n4": (49, 53, 82), "n5": (63, 72, 102), "n6": (86, 96, 126), "n7": (122, 131, 160),
    "w0": (31, 20, 16), "w1": (51, 32, 26), "w2": (74, 46, 33),
    "f0": (194, 128, 58), "f1": (219, 160, 74), "f2": (240, 192, 96), "f3": (255, 224, 138), "f4": (255, 244, 204),
    "a0": (58, 29, 74), "a1": (107, 47, 122), "a2": (160, 80, 176),
}
BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]


def sky(img):
    """Cielo a bande verticali con passaggio dithered tra una banda e l'altra."""
    px = img.load()
    bands = [("n0", 0), ("n1", 120), ("n2", 230), ("n3", 330), ("n4", 400)]
    for y in range(H):
        for i in range(len(bands) - 1):
            if bands[i][1] <= y < bands[i + 1][1]:
                c0, c1, y0, y1 = bands[i][0], bands[i + 1][0], bands[i][1], bands[i + 1][1]
                break
        else:
            c0 = c1 = bands[-1][0]
            y0, y1 = bands[-1][1], H
        t = (y - y0) / max(1, (y1 - y0))
        for x in range(W):
            thr = (BAYER[y % 4][x % 4] + 0.5) / 16
            px[x, y] = C[c1] if t > 0.55 + 0.45 * thr else C[c0]


def stars(d, rnd):
    for _ in range(70):
        x, y = rnd.randrange(W), rnd.randrange(10, 300)
        d.point((x, y), fill=C[rnd.choice(["n6", "n5", "n7"])])


def moon(img, d, cx, cy, r):
    # alone
    for rr, col in ((r + 14, "n4"), (r + 8, "n5")):
        for y in range(cy - rr, cy + rr + 1):
            for x in range(cx - rr, cx + rr + 1):
                if (x - cx) ** 2 + (y - cy) ** 2 <= rr * rr and BAYER[y % 4][x % 4] < (6 if col == "n4" else 9):
                    if 0 <= x < W and 0 <= y < H:
                        img.putpixel((x, y), C[col])
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=C["f4"])
    # ombreggiatura fredda e crateri
    for y in range(cy - r, cy + r + 1):
        for x in range(cx - r, cx + r + 1):
            dx, dy = x - cx, y - cy
            if dx * dx + dy * dy <= r * r and dx + dy * 0.3 > r * 0.35:
                img.putpixel((x, y), C["n7"] if BAYER[y % 4][x % 4] < 8 else C["f4"])
    for ox, oy, rr in ((-6, -4, 3), (4, 6, 2), (-2, 8, 2)):
        d.ellipse([cx + ox - rr, cy + oy - rr, cx + ox + rr, cy + oy + rr], fill=C["n7"])


def clouds(d, rnd):
    """Strisce di nuvole orizzontali che velano la luna e il cielo."""
    for y0, col, n in ((90, "n3", 5), (150, "n2", 6), (205, "n3", 5), (300, "n4", 6)):
        for _ in range(n):
            x = rnd.randrange(-60, W)
            w = rnd.randrange(60, 160)
            h = rnd.randrange(3, 7)
            y = y0 + rnd.randrange(-12, 12)
            d.rectangle([x, y, x + w, y + h], fill=C[col])
            d.rectangle([x + 8, y - 2, x + w - 14, y], fill=C[col])
            d.line([(x + 6, y + h + 1), (x + w - 4, y + h + 1)], fill=C["n1"])


def cathedral(d, cx, base_y):
    """Silhouette della cattedrale: guglia centrale, due torri, rosone acceso."""
    col, edge = C["n0"], C["n2"]
    # corpo
    d.rectangle([cx - 70, base_y - 120, cx + 70, base_y], fill=col)
    # torri laterali con pinnacoli
    for tx in (cx - 62, cx + 46):
        d.rectangle([tx, base_y - 190, tx + 16, base_y - 120], fill=col)
        d.polygon([(tx - 2, base_y - 190), (tx + 8, base_y - 232), (tx + 18, base_y - 190)], fill=col)
        d.line([(tx + 8, base_y - 232), (tx + 8, base_y - 240)], fill=col)
    # guglia centrale
    d.rectangle([cx - 14, base_y - 220, cx + 14, base_y - 120], fill=col)
    d.polygon([(cx - 16, base_y - 220), (cx, base_y - 262), (cx + 16, base_y - 220)], fill=col)
    d.line([(cx, base_y - 262), (cx, base_y - 274)], fill=col)
    d.line([(cx - 4, base_y - 269), (cx + 4, base_y - 269)], fill=col)
    # profilo illuminato dalla luna (lato sinistro)
    d.line([(cx - 16, base_y - 220), (cx, base_y - 262)], fill=edge)
    # contrafforti e cornici del corpo
    for bx in (cx - 70, cx - 36, cx + 30, cx + 64):
        d.line([(bx, base_y - 118), (bx, base_y)], fill=edge)
    d.line([(cx - 70, base_y - 121), (cx + 70, base_y - 121)], fill=edge)
    d.polygon([(cx - 70, base_y - 120), (cx, base_y - 150), (cx + 70, base_y - 120)], fill=col)
    d.line([(cx - 70, base_y - 120), (cx, base_y - 150)], fill=edge)
    for tx in (cx - 62, cx + 46):
        d.line([(tx - 2, base_y - 190), (tx + 8, base_y - 232)], fill=edge)
    # rosone e finestre a sesto acuto
    rx, ry = cx, base_y - 185
    d.ellipse([rx - 8, ry - 8, rx + 8, ry + 8], fill=C["a0"])
    d.ellipse([rx - 5, ry - 5, rx + 5, ry + 5], fill=C["a1"])
    d.point((rx, ry), fill=C["a2"])
    for wx in (cx - 44, cx - 24, cx + 20, cx + 40):
        d.rectangle([wx, base_y - 95, wx + 5, base_y - 70], fill=C["w1"])
        d.polygon([(wx, base_y - 95), (wx + 2, base_y - 100), (wx + 5, base_y - 95)], fill=C["w1"])
        d.rectangle([wx + 1, base_y - 92, wx + 4, base_y - 72], fill=C["f0"])


def rooftops(d, rnd, y_base, color, edge, windows, height=(30, 80)):
    x = -10
    while x < W:
        w = rnd.randrange(26, 54)
        h = rnd.randrange(*height)
        top = y_base - h
        d.rectangle([x, top, x + w, H], fill=color)
        roof = rnd.choice(["gable", "flat", "gable"])
        if roof == "gable":
            peak = top - rnd.randrange(10, 22)
            d.polygon([(x - 3, top), (x + w // 2, peak), (x + w + 3, top)], fill=color)
            d.line([(x - 3, top), (x + w // 2, peak)], fill=edge)
        else:
            d.line([(x, top), (x + w, top)], fill=edge)
        if rnd.random() < 0.6:   # camino
            cxp = x + rnd.randrange(4, max(5, w - 8))
            d.rectangle([cxp, top - 16, cxp + 5, top], fill=color)
            d.line([(cxp, top - 16), (cxp + 5, top - 16)], fill=edge)
        if windows:
            for _ in range(rnd.randrange(0, 4)):
                wx = x + rnd.randrange(3, max(4, w - 6))
                wy = top + rnd.randrange(8, max(9, h - 6))
                lit = rnd.random() < 0.55
                d.rectangle([wx, wy, wx + 3, wy + 4], fill=C["f1"] if lit else C["n2"])
                if lit:
                    d.point((wx + 1, wy + 1), fill=C["f3"])
        x += w + rnd.randrange(0, 6)


def ledge(d, y):
    """Cornicione di pietra in primo piano con rune viola incise."""
    d.rectangle([0, y, W, H], fill=C["n1"])
    d.rectangle([0, y, W, y + 3], fill=C["n3"])
    d.line([(0, y), (W, y)], fill=C["n5"])
    for bx in range(0, W, 40):   # blocchi di pietra
        d.line([(bx, y + 4), (bx, y + 26)], fill=C["n0"])
    d.line([(0, y + 26), (W, y + 26)], fill=C["n0"])
    runes = [
        [(0, 0), (0, 8), (0, 4), (4, 0), (0, 4), (4, 8)],
        [(2, 0), (2, 8), (0, 2), (4, 2)],
        [(0, 8), (2, 0), (4, 8), (1, 4), (3, 4)],
        [(0, 0), (4, 4), (0, 8), (4, 4), (4, 0)],
    ]
    x = 30
    for i in range(7):
        pts = [(x + px, y + 10 + py) for px, py in runes[i % len(runes)]]
        d.line(pts, fill=C["a2"])
        x += 48


def build(seed=7):
    rnd = random.Random(seed)
    img = Image.new("RGB", (W, H), C["n0"])
    d = ImageDraw.Draw(img)
    sky(img)
    stars(d, rnd)
    moon(img, d, 70, 250, 20)
    clouds(d, rnd)
    rooftops(d, rnd, 470, C["n3"], C["n4"], windows=False, height=(20, 60))     # città lontana
    cathedral(d, 250, 480)
    rooftops(d, rnd, 520, C["n2"], C["n4"], windows=True, height=(10, 60))      # tetti medi
    rooftops(d, rnd, 575, C["n1"], C["n3"], windows=True, height=(5, 40))       # tetti vicini
    ledge(d, 598)
    return img


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 7
    img = build(seed)
    img.save(out / "title_bg.png")
    img.resize((W * 2, H * 2), Image.NEAREST).save(out / "title_bg_preview.png")
    print("title_bg", img.size)


if __name__ == "__main__":
    main()
