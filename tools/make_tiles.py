#!/usr/bin/env python3
"""
Clues & Curses - Tessere della griglia e icone UI disegnate via codice (GDD #05: G1-G4, U1-U3).
Solo colori della palette del gioco, pixel esatti, nessuna sfumatura.

v2 (GDD #07): rune del Sigillo Runico (16x16, quattro stati: incisa = data dal puzzle,
inchiostro = posata dal giocatore, accesa = vittoria, errore) e icona del suggerimento.
Le cime del puzzle a frecce sono disegnate direttamente da ArrowGridUI.gd.

Uso:  python3 make_tiles.py [cartella_uscita]      (predefinita: out/tiles)
Produce i PNG alla dimensione finale + _tiles_preview.png ingrandita x8.
I nomi cell_empty / cell_filled / cell_marked sono quelli che PuzzleTest.gd carica gia'.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

P = {  # palette Clues & Curses (GDD #05)
    "n0": "#0b0a12", "n1": "#14121f", "n2": "#1c1b2e", "n3": "#262640", "n4": "#313552",
    "n5": "#3f4866", "n6": "#56607e", "n7": "#7a83a0",
    "w0": "#1f1410", "w1": "#33201a", "w2": "#4a2e21", "w3": "#66412b", "w4": "#85593a", "w5": "#a8774f",
    "f0": "#c2803a", "f1": "#dba04a", "f2": "#f0c060", "f3": "#ffe08a", "f4": "#fff4cc",
    "b0": "#3d0c11", "b1": "#6b1219", "b2": "#9c1d22", "b3": "#cc3a2e",
    "a0": "#3a1d4a", "a1": "#6b2f7a", "a2": "#a050b0",
}


def new(size, fill=None):
    return Image.new("RGBA", (size, size), P[fill] if fill else (0, 0, 0, 0))


def px(img, x, y, c):
    img.putpixel((x, y), Image.new("RGB", (1, 1), P[c]).getpixel((0, 0)) + (255,))


def stamp(img, rows, colors, ox=0, oy=0):
    """Disegna una mappa di caratteri: ogni carattere -> chiave di colore, '.' = trasparente."""
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch != ".":
                px(img, ox + x, oy + y, colors[ch])


def bevel(img, x0, y0, x1, y1, light, dark, fill=None):
    d = ImageDraw.Draw(img)
    if fill:
        d.rectangle([x0, y0, x1, y1], fill=P[fill])
    d.line([(x0, y0), (x1, y0)], fill=P[light]); d.line([(x0, y0), (x0, y1)], fill=P[light])
    d.line([(x0, y1), (x1, y1)], fill=P[dark]); d.line([(x1, y0), (x1, y1)], fill=P[dark])


# =====================================================================
# G1-G4: celle 16x16
# =====================================================================
def cell_empty():
    # pergamena scura: fondo notte con smusso, due "fibre" per non sembrare piatta
    img = new(16, "n2")
    bevel(img, 0, 0, 15, 15, "n4", "n0")
    for x, y in ((4, 5), (10, 9), (6, 12)):
        px(img, x, y, "n3")
    return img


def cell_filled():
    # cella "incisa" in oro: contrasto forte sul fondo notte, coerente con solved_tint
    img = new(16, "f1")
    bevel(img, 0, 0, 15, 15, "f3", "w3")
    bevel(img, 1, 1, 14, 14, "f2", "f0")
    for x, y in ((4, 4), (5, 4), (4, 5)):
        px(img, x, y, "f4")   # riflesso in alto a sinistra
    return img


def x_mark(img, main, shade):
    for i in range(4, 12):
        px(img, i, i, main); px(img, 15 - i, i, main)
        if i < 11:
            px(img, i + 1, i, shade); px(img, 14 - i, i, shade)   # spessore e ombra a destra
    return img


def cell_marked():
    return x_mark(cell_empty(), "n7", "n5")


def cell_error():
    return x_mark(cell_empty(), "b3", "b1")


# =====================================================================
# U1: Concentrazione (occhio nel cerchio runico) 16x16
# =====================================================================
EYE_RING = [
    "......kkkk......",
    "....kk....kk....",
    "...k........k...",
    "..k..........k..",
    ".k............k.",
    ".k............k.",
    "k..............k",
    "k..............k",
    "k..............k",
    "k..............k",
    ".k............k.",
    ".k............k.",
    "..k..........k..",
    "...k........k...",
    "....kk....kk....",
    "......kkkk......",
]
EYE_OPEN = [
    "....oooooo....",
    "..oowwiiwwoo..",
    ".owwiippiiwwo.",
    "owwwiipqiiwwwo",
    ".owwiiiiiiwwo.",
    "..oowwiiwwoo..",
    "....oooooo....",
]
EYE_SHUT = [
    "..............",
    "..............",
    "..............",
    "oooooooooooooo",
    "..o..o..o..o..",
    "..............",
    "..............",
]


def concentration(full):
    img = new(16)
    ring = "a2" if full else "n5"
    stamp(img, EYE_RING, {"k": ring})
    if full:
        stamp(img, EYE_OPEN, {"o": "n0", "w": "f4", "i": "a2", "p": "a0", "q": "f4"}, 1, 5)
    else:
        stamp(img, EYE_SHUT, {"o": "n6"}, 1, 5)
    return img


# =====================================================================
# U3: Stelle 16x16
# =====================================================================
# meta' sinistra (colonna 7 = asse); la stella viene specchiata per essere simmetrica
STAR_HALF = [
    "........",
    ".......k",
    "......kf",
    "......kf",
    ".....kff",
    "kkkkkkff",
    ".kffffff",
    "..kfffff",
    "...kffff",
    "....kfff",
    "....kfff",
    "...kfffk",
    "...kffk.",
    "..kfk...",
    "..kk....",
    "........",
]
STAR = [r + r[:-1][::-1] + "." for r in STAR_HALF]
STAR_SHINE = [(6, 4), (6, 5), (5, 6), (4, 6)]   # riflesso in alto a sinistra


def star(full):
    img = new(16)
    if full:
        stamp(img, STAR, {"k": "w2", "f": "f2"})
        for x, y in STAR_SHINE:
            px(img, x, y, "f4")
    else:
        empty = [r.replace("f", ".") for r in STAR]
        stamp(img, empty, {"k": "n6"})
    return img


# =====================================================================
# U2: Pulsanti 32x32 (cuoio e ottone) con icona
# =====================================================================
def button_base():
    img = new(32, "w1")
    bevel(img, 0, 0, 31, 31, "w4", "n0")
    bevel(img, 1, 1, 30, 30, "w3", "w0")
    for cx, cy in ((2, 2), (29, 2), (2, 29), (29, 29)):   # borchie d'ottone
        px(img, cx, cy, "f1")
    return img


QUILL = [
    "............hh",
    "..........hhfh",
    "........hhffh.",
    ".......hffffh.",
    "......hfffhh..",
    ".....hfffh....",
    "....hffhh.....",
    "...hffh.......",
    "...hfh........",
    "..hhh.........",
    "..k...........",
    ".kk...........",
    "kk............",
    "k.............",
]
UNDO = [
    "....kk..........",
    "...kfk..........",
    "..kffkkkkkkk....",
    ".kfffffffffffk..",
    "..kffkkkkkkkffk.",
    "...kfk......kfk.",
    "....kk.......kfk",
    ".............kfk",
    ".............kfk",
    "............kffk",
    "..kkkkkkkkkkffk.",
    "..kffffffffffk..",
    "..kkkkkkkkkkk...",
]


def button_fill():
    img = button_base()
    stamp(img, QUILL, {"h": "n7", "f": "f4", "k": "n0"}, 9, 9)
    return img


def button_mark():
    img = button_base()
    for i in range(9, 23):
        for w in (0, 1):
            px(img, i + w, i, "f4"); px(img, 31 - i - w, i, "f4")
        px(img, i, i + 1, "w0"); px(img, 31 - i, i + 1, "w0")   # ombra sotto
    return img


def button_undo():
    img = button_base()
    stamp(img, UNDO, {"k": "n0", "f": "f4"}, 8, 9)
    return img


# =====================================================================
# GDD #07 - Rune del Sigillo Runico (glifi 16x16 su fondo trasparente)
# Tratti di 2 px, ispirati al Futhark antico. Si appoggiano sopra cell_empty.
# =====================================================================
RUNES = {
    # ᚨ asta verticale con due rami che scendono a destra
    "ansuz": [
        "................",
        "...##...........",
        "...###..........",
        "...####.........",
        "...##.##........",
        "...##..##.......",
        "...###..##......",
        "...####..##.....",
        "...##.##........",
        "...##..##.......",
        "...##...##......",
        "...##...........",
        "...##...........",
        "...##...........",
        "...##...........",
        "................",
    ],
    # ᚠ asta verticale con due rami che salgono a destra
    "fehu": [
        "................",
        "...##......##...",
        "...##.....##....",
        "...##....##.....",
        "...##...##......",
        "...##..##..##...",
        "...##.##..##....",
        "...####..##.....",
        "...###..##......",
        "...##..##.......",
        "...##.##........",
        "...####.........",
        "...###..........",
        "...##...........",
        "...##...........",
        "................",
    ],
    # ᛁ una sola asta, con un piccolo pomo per non sembrare una lineetta
    "isa": [
        "................",
        "......####......",
        ".......##.......",
        ".......##.......",
        ".......##.......",
        ".......##.......",
        ".......##.......",
        ".......##.......",
        ".......##.......",
        ".......##.......",
        ".......##.......",
        ".......##.......",
        ".......##.......",
        "......####......",
        "................",
        "................",
    ],
    # ᛟ rombo in alto con due gambe incrociate
    "othala": [
        "................",
        ".......##.......",
        "......####......",
        ".....##..##.....",
        "....##....##....",
        "...##......##...",
        "....##....##....",
        ".....##..##.....",
        "......####......",
        ".....######.....",
        "....##....##....",
        "...##......##...",
        "..##........##..",
        ".##..........##.",
        "................",
        "................",
    ],
    # ᚲ angolo aperto a destra
    "kenaz": [
        "................",
        "..........##....",
        ".........##.....",
        "........##......",
        ".......##.......",
        "......##........",
        ".....##.........",
        "....##..........",
        "....##..........",
        ".....##.........",
        "......##........",
        ".......##.......",
        "........##......",
        ".........##.....",
        "..........##....",
        "................",
    ],
    # ᛏ freccia verso l'alto
    "tiwaz": [
        "................",
        ".......##.......",
        "......####......",
        ".....##..##.....",
        "....##.##.##....",
        "...##..##..##...",
        "..##...##...##..",
        ".......##.......",
        ".......##.......",
        ".......##.......",
        ".......##.......",
        ".......##.......",
        ".......##.......",
        ".......##.......",
        ".......##.......",
        "................",
    ],
}

# stato -> (colore del tratto, colore dell'ombra in basso a destra)
RUNE_STATES = {
    "carved": ("n7", "n0"),   # data dal puzzle: incisa nella pietra
    "ink": ("f2", "w2"),      # posata dal giocatore
    "lit": ("f4", "f0"),      # vittoria: le rune si accendono
    "error": ("b3", "b0"),    # runa sbagliata (lampo prima di sparire)
}


def rune(name, state):
    img = new(16)
    main, shade = RUNE_STATES[state]
    rows = RUNES[name]
    for y, row in enumerate(rows):      # ombra: 1 px in basso a destra
        for x, ch in enumerate(row):
            if ch == "#" and x + 1 < 16 and y + 1 < 16 and rows[y + 1][x + 1] != "#":
                px(img, x + 1, y + 1, shade)
    stamp(img, rows, {"#": main})
    return img


HINT = [
    "......kk......",
    "....kkffkk....",
    "...kffffffk...",
    "..kfffwwfffk..",
    "..kffwwffffk..",
    "..kffwfffffk..",
    "...kffffffk...",
    "....kffffk....",
    ".....kffk.....",
    ".....kkkk.....",
    ".....knnk.....",
    ".....kkkk.....",
    "......kk......",
]


def icon_hint():
    # lanterna/lampadina dell'aiuto (GDD #07: evidenzia una mossa libera)
    img = new(16)
    stamp(img, HINT, {"k": "n0", "f": "f2", "w": "f4", "n": "n6"}, 1, 1)
    return img


TILES = {
    "cell_empty": cell_empty, "cell_filled": cell_filled, "cell_marked": cell_marked, "cell_error": cell_error,
    "icon_concentration_full": lambda: concentration(True), "icon_concentration_empty": lambda: concentration(False),
    "icon_star_full": lambda: star(True), "icon_star_empty": lambda: star(False),
    "btn_fill": button_fill, "btn_mark": button_mark, "btn_undo": button_undo,
    "icon_hint": icon_hint,
}
for _rune in RUNES:
    for _state in RUNE_STATES:
        TILES[f"rune_{_rune}_{_state}"] = (lambda r=_rune, s=_state: rune(r, s))


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "out/tiles")
    out.mkdir(parents=True, exist_ok=True)
    imgs = {}
    for name, fn in TILES.items():
        imgs[name] = fn()
        sub = out / "runes" if name.startswith("rune_") else out
        sub.mkdir(parents=True, exist_ok=True)
        imgs[name].save(sub / f"{name}.png")
    # anteprima x8 su fondo #14121f, una riga per le tessere e una per le rune
    s = 8
    rows = [[i for n, i in imgs.items() if not n.startswith("rune_")],
            [i for n, i in imgs.items() if n.startswith("rune_")]]
    w = max(sum(i.width * s + 16 for i in r) for r in rows) + 16
    prev = Image.new("RGBA", (w, 2 * (32 * s + 32)), P["n1"])
    for k, row in enumerate(rows):
        x = 16
        for i in row:
            base = cell_empty().resize((16 * s, 16 * s), Image.NEAREST) if k == 1 else None
            if base:
                prev.alpha_composite(base, (x, 16 + k * (32 * s + 32)))
            prev.alpha_composite(i.resize((i.width * s, i.height * s), Image.NEAREST), (x, 16 + k * (32 * s + 32)))
            x += i.width * s + 16
    prev.save(out / "_tiles_preview.png")
    print(f"{len(imgs)} immagini in {out}/")


if __name__ == "__main__":
    main()
