#!/usr/bin/env python3
"""
Clues & Curses - Pulizia automatica degli asset generati da Gemini (GDD #05, sezione 5).

MODALITA'
  portrait    ritratti 160x200: via il magenta, inquadratura, palette, contorno scuro
  background  sfondi 360x640: niente magenta, ritaglio 9:16, palette (dithering opzionale)
  item        oggetti delle prove 64x64: via il magenta, ritaglio quadrato sul soggetto
  ui          elementi decorativi: come item, con 9-slice simmetrico opzionale

USO
  Un file:   python3 clean_assets.py one INPUT OUTPUT.png --mode portrait --size 160x200
  Batch:     python3 clean_assets.py batch assets_manifest.json
             (legge le immagini da "input_dir", scrive in "output_dir",
              produce una tavola di confronto _contact_sheet.png)

RITRATTI DELLO STESSO PERSONAGGIO
  Nel manifest i ritratti con lo stesso "group" (es. "garrett") usano la stessa scala:
  la dimensione della testa resta uguale tra un'espressione e l'altra e il ritratto
  non "salta" nel dialogo. Correzioni fini per singolo file: "scale" (es. 1.05) e
  "offset" ([dx, dy] in pixel finali).

Il ritocco a mano (mani, occhi, pendente, oggetti indesiderati) resta da fare in Aseprite:
lo script porta l'immagine all'80%, non al 100%.
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
OUTLINE = 0  # indice di #0b0a12 nella palette

DEFAULT_SIZES = {"portrait": (160, 200), "background": (360, 640), "item": (64, 64), "ui": (48, 48)}


# =====================================================================
# Palette e colore
# =====================================================================
def load_palette(path):
    cols = [l.strip().lstrip("#") for l in Path(path).read_text().splitlines()
            if l.strip() and not l.startswith(("GIMP", "Name", "Columns", "#"))]
    return np.array([[int(c[i:i + 2], 16) for i in (0, 2, 4)] for c in cols], dtype=np.float64)


def rgb_to_lab(rgb):
    c = rgb / 255.0
    c = np.where(c > 0.04045, ((c + 0.055) / 1.055) ** 2.4, c / 12.92)
    m = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = c @ m.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


CHROMA_WEIGHT = 0.6  # <1: conta di piu' la luminosita' -> pelli e capelli meno "accesi"


def nearest_index(rgb, pal_lab, dither=0.0, banned=()):
    """Indice del colore di palette piu' vicino (Lab pesato). dither > 0: Bayer 4x4 ordinato.
    banned: indici di palette da non usare (es. i rossi accesi sulla pelle)."""
    if dither > 0:
        bayer = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]) / 16.0 - 0.47
        h, w = rgb.shape[:2]
        tile = np.tile(bayer, (h // 4 + 1, w // 4 + 1))[:h, :w]
        rgb = np.clip(rgb + tile[..., None] * dither * 32, 0, 255)
    w = np.array([1.0, CHROMA_WEIGHT, CHROMA_WEIGHT])
    lab = rgb_to_lab(rgb)
    d = (((lab[..., None, :] - pal_lab[None, None, :, :]) * w) ** 2).sum(-1)
    for b in banned:
        d[..., b] = np.inf
    return d.argmin(-1)


def hex_to_indices(pal, hexes):
    out = []
    for h in hexes:
        h = h.lstrip("#").lower()
        rgb = [int(h[i:i + 2], 16) for i in (0, 2, 4)]
        hit = np.where((pal == rgb).all(1))[0]
        if len(hit):
            out.append(int(hit[0]))
    return out


# =====================================================================
# Sfondo magenta
# =====================================================================
def magenta_mask(rgb):
    """True dove il pixel e' sfondo magenta (anche sporco o con grana JPEG)."""
    r, g, b = rgb[..., 0].astype(int), rgb[..., 1].astype(int), rgb[..., 2].astype(int)
    return (r > 170) & (b > 170) & (g < 110) & (np.abs(r - b) < 80)


def keep_main_subject(alpha, min_ratio=0.02):
    """Toglie le macchie staccate dal soggetto (residui, scintille) piu' piccole del 2%."""
    from collections import deque
    h, w = alpha.shape
    seen = np.zeros_like(alpha)
    comps = []
    for y0 in range(0, h, 2):
        for x0 in range(0, w, 2):
            if alpha[y0, x0] and not seen[y0, x0]:
                q = deque([(y0, x0)])
                seen[y0, x0] = True
                pts = []
                while q:
                    y, x = q.popleft()
                    pts.append((y, x))
                    for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
                        if 0 <= ny < h and 0 <= nx < w and alpha[ny, nx] and not seen[ny, nx]:
                            seen[ny, nx] = True
                            q.append((ny, nx))
                comps.append(pts)
    if not comps:
        return alpha
    biggest = max(len(c) for c in comps)
    out = np.zeros_like(alpha)
    for c in comps:
        if len(c) >= biggest * min_ratio:
            ys, xs = zip(*c)
            out[list(ys), list(xs)] = True
    return out


# =====================================================================
# Riduzione e rifinitura
# =====================================================================
def block_reduce(rgb, alpha, out_w, out_h):
    """Per ogni pixel di uscita: mediana dei pixel opachi al centro del blocco
    (il centro evita i colori di "cucitura" tra due pixel di Gemini)."""
    h, w = alpha.shape
    ys = np.linspace(0, h, out_h + 1).astype(int)
    xs = np.linspace(0, w, out_w + 1).astype(int)
    out = np.zeros((out_h, out_w, 3))
    out_a = np.zeros((out_h, out_w), bool)
    for j in range(out_h):
        y0, y1 = ys[j], ys[j + 1]
        my = (y1 - y0) // 4
        for i in range(out_w):
            x0, x1 = xs[i], xs[i + 1]
            mx = (x1 - x0) // 4
            ba = alpha[y0 + my:max(y0 + my + 1, y1 - my), x0 + mx:max(x0 + mx + 1, x1 - mx)]
            if ba.size == 0 or ba.mean() < 0.5:
                continue
            blk = rgb[y0 + my:max(y0 + my + 1, y1 - my), x0 + mx:max(x0 + mx + 1, x1 - mx)]
            out_a[j, i] = True
            out[j, i] = np.median(blk[ba], axis=0)
    return out, out_a


def remove_orphans(idx, alpha):
    """Un pixel diverso dai 4 vicini (uguali tra loro) prende il loro colore."""
    res = idx.copy()
    h, w = idx.shape
    for y in range(1, h - 1):
        for x in range(1, w - 1):
            if not alpha[y, x]:
                continue
            n = (idx[y - 1, x], idx[y + 1, x], idx[y, x - 1], idx[y, x + 1])
            if alpha[y - 1, x] and alpha[y + 1, x] and alpha[y, x - 1] and alpha[y, x + 1] \
                    and n.count(n[0]) == 4 and n[0] != idx[y, x]:
                res[y, x] = n[0]
    return res


def fix_fringe(idx, alpha, pal, depth=2):
    """Alone magenta sul bordo -> contorno #0b0a12 (GDD #05: contorno di 1 pixel)."""
    p = pal[idx]
    violet = (p[..., 0] > p[..., 1] + 25) & (p[..., 2] > p[..., 1] + 25)
    res = idx.copy()
    edge = ~alpha
    for _ in range(depth):
        near = np.zeros_like(alpha)
        near[1:] |= edge[:-1]; near[:-1] |= edge[1:]
        near[:, 1:] |= edge[:, :-1]; near[:, :-1] |= edge[:, 1:]
        hit = near & alpha & violet & (res != OUTLINE)
        res[hit] = OUTLINE
        edge = edge | hit
    return res


def crop_canvas(rgb, alpha, x0, y0, bw, bh):
    """Ritaglio che puo' uscire dall'immagine (fuori = trasparente)."""
    out_rgb = np.zeros((bh, bw, 3))
    out_a = np.zeros((bh, bw), bool)
    sx0, sy0 = max(0, x0), max(0, y0)
    sx1, sy1 = min(rgb.shape[1], x0 + bw), min(rgb.shape[0], y0 + bh)
    if sx1 > sx0 and sy1 > sy0:
        out_rgb[sy0 - y0:sy1 - y0, sx0 - x0:sx1 - x0] = rgb[sy0:sy1, sx0:sx1]
        out_a[sy0 - y0:sy1 - y0, sx0 - x0:sx1 - x0] = alpha[sy0:sy1, sx0:sx1]
    return out_rgb, out_a


def bbox(alpha):
    ys, xs = np.nonzero(alpha)
    return xs.min(), ys.min(), xs.max() + 1, ys.max() + 1


# =====================================================================
# Inquadrature per modalita'
# =====================================================================
def frame_portrait(rgb, alpha, out_w, out_h, src_per_px, scale=1.0, offset=(0, 0)):
    """Ritratto: scala FISSA (src_per_px pixel sorgente per pixel finale, comune al gruppo),
    centrato sul soggetto in orizzontale, testa a ~6% dal bordo superiore."""
    k = src_per_px / scale
    bw, bh = int(round(out_w * k)), int(round(out_h * k))
    x0, y0, x1, _ = bbox(alpha)
    cx = (x0 + x1) // 2
    top = y0 - int(bh * 0.06)
    return crop_canvas(rgb, alpha, cx - bw // 2 - int(offset[0] * k), top - int(offset[1] * k), bw, bh)


def portrait_scale(alpha, out_w, out_h):
    """Scala naturale di un ritratto: soggetto alto quanto ~1.05 volte il riquadro
    (il busto esce dal bordo inferiore, come nei dialoghi)."""
    x0, y0, x1, y1 = bbox(alpha)
    return max((y1 - y0) / (out_h * 1.0), (x1 - x0) / (out_w * 0.98))


def frame_square_subject(rgb, alpha, out_w, out_h, pad=0.08):
    x0, y0, x1, y1 = bbox(alpha)
    side_w, side_h = x1 - x0, y1 - y0
    aspect = out_w / out_h
    bw = max(side_w, side_h * aspect) * (1 + 2 * pad)
    bh = bw / aspect
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    return crop_canvas(rgb, alpha, int(cx - bw / 2), int(cy - bh / 2), int(bw), int(bh))


def frame_background(rgb, out_w, out_h):
    h, w = rgb.shape[:2]
    aspect = out_w / out_h
    if w / h > aspect:
        nw = int(h * aspect)
        x0 = (w - nw) // 2
        rgb = rgb[:, x0:x0 + nw]
    else:
        nh = int(w / aspect)
        y0 = (h - nh) // 2
        rgb = rgb[y0:y0 + nh]
    return rgb, np.ones(rgb.shape[:2], bool)


def mirror_nine_slice(idx, alpha):
    """9-slice simmetrico: il quarto in alto a sinistra viene specchiato sugli altri tre."""
    h, w = idx.shape
    hh, hw = (h + 1) // 2, (w + 1) // 2
    for arr in (idx, alpha):
        q = arr[:hh, :hw].copy()
        arr[:hh, w - hw:] = q[:, ::-1]
        arr[h - hh:, :hw] = q[::-1, :]
        arr[h - hh:, w - hw:] = q[::-1, ::-1]
    return idx, alpha


# =====================================================================
# Pipeline
# =====================================================================
def load_rgb(src):
    return np.asarray(Image.open(src).convert("RGB")).astype(np.float64)


def subject_alpha(rgb):
    return keep_main_subject(~magenta_mask(rgb))


def process(src, mode, size, pal, pal_lab, src_per_px=None, scale=1.0, offset=(0, 0),
            dither=0.0, nine_slice=False, banned=()):
    rgb = load_rgb(src)
    out_w, out_h = size
    keyed = mode != "background"
    if keyed:
        alpha = subject_alpha(rgb)
        if mode == "portrait":
            if src_per_px is None:
                src_per_px = portrait_scale(alpha, out_w, out_h)
            rgb, alpha = frame_portrait(rgb, alpha, out_w, out_h, src_per_px, scale, offset)
        else:
            rgb, alpha = frame_square_subject(rgb, alpha, out_w, out_h)
    else:
        rgb, alpha = frame_background(rgb, out_w, out_h)

    small, small_a = block_reduce(rgb, alpha, out_w, out_h)
    idx = nearest_index(small, pal_lab, dither, banned)
    idx = remove_orphans(idx, small_a)
    if keyed:
        idx = fix_fringe(idx, small_a, pal)
    if nine_slice:
        idx, small_a = mirror_nine_slice(idx, small_a)

    out = np.zeros((out_h, out_w, 4), np.uint8)
    out[..., :3] = pal[idx].astype(np.uint8)
    out[..., 3] = np.where(small_a, 255, 0)
    return Image.fromarray(out, "RGBA"), len(np.unique(idx[small_a]))


def save_with_preview(img, dst, factor=4):
    dst = Path(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    img.save(dst)
    prev = Image.new("RGBA", img.size, (38, 38, 64, 255))  # #262640, per vedere i bordi
    prev.alpha_composite(img)
    prev = prev.resize((img.width * factor, img.height * factor), Image.NEAREST)
    prev.save(dst.with_name(dst.stem + "_preview.png"))
    return prev


def contact_sheet(entries, path, cell_h=400):
    """Tavola di revisione: le anteprime raggruppate per gruppo, una riga per gruppo,
    con una guida orizzontale all'altezza degli occhi per confrontare la scala."""
    rows = {}
    for e in entries:
        rows.setdefault(e["group"], []).append(e)
    lines = []
    for group, items in rows.items():
        thumbs = []
        for e in items:
            im = Image.open(e["preview"]).convert("RGBA")
            t = im.resize((int(im.width * cell_h / im.height), cell_h), Image.NEAREST)
            thumbs.append((e["id"], t))
        w = sum(t.width for _, t in thumbs) + 12 * (len(thumbs) + 1)
        row = Image.new("RGBA", (max(w, 300), cell_h + 40), (11, 10, 18, 255))
        d = ImageDraw.Draw(row)
        d.text((12, 6), group, fill=(240, 192, 96, 255))
        x = 12
        for aid, t in thumbs:
            row.paste(t, (x, 26))
            d.text((x + 4, 26 + cell_h - 14), aid, fill=(255, 244, 204, 255))
            x += t.width + 12
        if items[0]["mode"] == "portrait":
            gy = 26 + int(cell_h * 0.30)  # occhi ~30% dall'alto: devono stare sulla stessa riga
            d.line([(0, gy), (row.width, gy)], fill=(204, 58, 46, 160), width=1)
        lines.append(row)
    sheet = Image.new("RGBA", (max(r.width for r in lines), sum(r.height for r in lines)), (11, 10, 18, 255))
    y = 0
    for r in lines:
        sheet.paste(r, (0, y))
        y += r.height
    sheet.save(path)


def run_batch(manifest_path):
    manifest_path = Path(manifest_path)
    m = json.loads(manifest_path.read_text(encoding="utf-8"))
    base = manifest_path.parent
    in_dir = base / m.get("input_dir", "raw")
    out_dir = base / m.get("output_dir", "out")
    pal = load_palette(base / m.get("palette", "CluesAndCurses.hex"))
    pal_lab = rgb_to_lab(pal)

    assets = [a for a in m["assets"] if not a.get("skip")]
    missing = [a["id"] for a in assets if not (in_dir / a["file"]).exists()]
    todo = [a for a in assets if (in_dir / a["file"]).exists()]

    # Scala comune per gruppo di ritratti: la piu' "larga" tra le espressioni,
    # cosi' nessun ritratto del gruppo viene tagliato in alto o ai lati.
    group_scale = {}
    for a in todo:
        if a["mode"] != "portrait":
            continue
        size = tuple(a.get("size", DEFAULT_SIZES["portrait"]))
        alpha = subject_alpha(load_rgb(in_dir / a["file"]))
        s = portrait_scale(alpha, *size)
        g = a.get("group", a["id"])
        group_scale[g] = max(group_scale.get(g, 0), s)

    done = []
    for a in todo:
        mode = a["mode"]
        size = tuple(a.get("size", DEFAULT_SIZES[mode]))
        g = a.get("group", mode)
        img, used = process(in_dir / a["file"], mode, size, pal, pal_lab,
                            src_per_px=group_scale.get(g) if mode == "portrait" else None,
                            scale=a.get("scale", 1.0), offset=tuple(a.get("offset", (0, 0))),
                            dither=a.get("dither", 0.0), nine_slice=a.get("nine_slice", False),
                            banned=hex_to_indices(pal, a.get("avoid", m.get("avoid_by_mode", {}).get(mode, []))))
        dst = out_dir / a.get("subdir", "") / f"{a['id']}.png"
        save_with_preview(img, dst)
        done.append({"id": a["id"], "group": g, "mode": mode,
                     "preview": dst.with_name(dst.stem + "_preview.png")})
        print(f"  OK   {a['id']:<28} {size[0]}x{size[1]}  {used} colori")

    for aid in missing:
        print(f"  --   {aid:<28} file non trovato in {in_dir.name}/")
    if done:
        contact_sheet(done, out_dir / "_contact_sheet.png")
        print(f"\nTavola di revisione: {out_dir / '_contact_sheet.png'}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    one = sub.add_parser("one", help="una sola immagine")
    one.add_argument("src")
    one.add_argument("dst")
    one.add_argument("--mode", choices=DEFAULT_SIZES, default="portrait")
    one.add_argument("--size", help="es. 160x200 (predefinita per modalita')")
    one.add_argument("--palette", default=str(HERE / "CluesAndCurses.hex"))
    one.add_argument("--dither", type=float, default=0.0, help="0 = nessuno, 0.5-1 per gli sfondi")
    one.add_argument("--nine-slice", action="store_true")
    bat = sub.add_parser("batch", help="tutti gli asset di un manifest JSON")
    bat.add_argument("manifest")
    a = ap.parse_args()

    if a.cmd == "batch":
        sys.exit(run_batch(a.manifest))
    size = tuple(int(v) for v in a.size.lower().split("x")) if a.size else DEFAULT_SIZES[a.mode]
    pal = load_palette(a.palette)
    img, used = process(a.src, a.mode, size, pal, rgb_to_lab(pal), dither=a.dither, nine_slice=a.nine_slice)
    save_with_preview(img, a.dst)
    print(f"{a.dst}: {size[0]}x{size[1]}, {used} colori della palette")


if __name__ == "__main__":
    main()
