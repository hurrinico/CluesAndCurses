#!/usr/bin/env python3
"""
Clues & Curses - Validatore dei puzzle (pipeline dei contenuti, GDD #04 sezione 8 e GDD #07).

Controlla che ogni enigma dei file dei casi sia risolvibile per SOLA LOGICA, senza
tirare a indovinare. Se il solver si blocca, l'enigma è ambiguo o richiede tentativi:
va ridisegnato. Il tipo si legge dal campo "type" del puzzle ("picross" se manca).

picross      line-solving riga per riga e colonna per colonna.
             Nebbia Arcanica (GDD #06): se il puzzle ha "fog": {"rows": [...], "cols": [...]},
             i numeri guida di quelle linee sono nascosti. Il solver non li usa finché non si
             diradano: ogni RIGA completata rivela la prima COLONNA ancora annebbiata (nell'ordine
             della lista) e ogni COLONNA completata rivela la prima RIGA annebbiata.
             Una linea è "completata" quando tutte le sue caselle piene sono state dedotte.

rune_sudoku  (Sigillo Runico) 1. la soluzione rispetta le regole del sudoku;
             2. le rune date coincidono con la soluzione;
             3. soluzione unica (backtracking che si ferma alla seconda soluzione);
             4. risolvibile con le sole deduzioni "singolo nudo" e "singolo nascosto",
                le stesse che userà un giocatore casual (niente tentativi).

arrows       (Cime Aggrovigliate) 1. ogni linea è un percorso di celle adiacenti dentro la griglia;
             2. nessuna cella è usata da due linee;
             3. svuotabile: si toglie a ripetizione una qualunque linea con traiettoria libera.
                Togliere una linea non blocca mai le altre (rimozione monotona), quindi se il
                greedy si blocca esiste un ciclo di dipendenze e il puzzle non ha soluzione.
             Riporta anche la "profondità" (in quanti turni minimi si svuota) come indice di
             difficoltà.

Uso:
    python3 validate_cases.py data/cases/case_01.json [altri file...]
    python3 validate_cases.py data/cases/          (tutti i .json della cartella)
    -v  mostra i dettagli (ordine della nebbia, ordine di rimozione delle cime)

Esce con codice 1 se almeno un enigma non è valido (utile in CI o in un hook git).
"""
import json
import sys
from pathlib import Path


# =====================================================================
# PICROSS
# =====================================================================
def hints(line):
    out, count = [], 0
    for v in line:
        if v:
            count += 1
        elif count:
            out.append(count)
            count = 0
    if count:
        out.append(count)
    return out or [0]


def candidates(clue, n):
    """Tutte le disposizioni di una linea di lunghezza n compatibili con i numeri guida."""
    if clue == [0]:
        return [(0,) * n]
    result = []

    def place(i, start, acc):
        if i == len(clue):
            result.append(tuple(acc + [0] * (n - len(acc))))
            return
        rest = sum(clue[i + 1:]) + len(clue[i + 1:])
        for s in range(start, n - rest - clue[i] + 1):
            seg = acc + [0] * (s - len(acc)) + [1] * clue[i]
            if i < len(clue) - 1:
                seg.append(0)
            place(i + 1, len(seg), seg)

    place(0, 0, [])
    return result


def solve_by_logic(solution, fog_rows=(), fog_cols=()):
    """Restituisce (celle non deducibili, celle dedotte in modo errato, ordine di rivelazione)."""
    rows, cols = len(solution), len(solution[0])
    grid = [[None] * cols for _ in range(rows)]
    row_opts = [candidates(hints(r), cols) for r in solution]
    col_opts = [candidates(hints([solution[r][c] for r in range(rows)]), rows) for c in range(cols)]
    fog_r, fog_c = list(fog_rows), list(fog_cols)
    done_r, done_c = set(), set()
    reveals = []

    # le linee vuote (numero guida 0) sono complete fin dall'inizio: non diradano la nebbia
    done_r.update(r for r in range(rows) if not any(solution[r]))
    done_c.update(c for c in range(cols) if not any(solution[r][c] for r in range(rows)))

    def row_complete(r):
        return all(grid[r][c] == 1 for c in range(cols) if solution[r][c] == 1)

    def col_complete(c):
        return all(grid[r][c] == 1 for r in range(rows) if solution[r][c] == 1)

    changed = True
    while changed:
        changed = False
        for r in range(rows):
            if r in fog_r:
                continue
            row_opts[r] = [l for l in row_opts[r]
                           if all(grid[r][c] is None or grid[r][c] == l[c] for c in range(cols))]
            for c in range(cols):
                vals = {l[c] for l in row_opts[r]}
                if grid[r][c] is None and len(vals) == 1:
                    grid[r][c] = vals.pop()
                    changed = True
        for c in range(cols):
            if c in fog_c:
                continue
            col_opts[c] = [l for l in col_opts[c]
                           if all(grid[r][c] is None or grid[r][c] == l[r] for r in range(rows))]
            for r in range(rows):
                vals = {l[r] for l in col_opts[c]}
                if grid[r][c] is None and len(vals) == 1:
                    grid[r][c] = vals.pop()
                    changed = True
        # la nebbia si dirada con le linee ortogonali completate
        for r in range(rows):
            if r not in done_r and row_complete(r):
                done_r.add(r)
                if fog_c:
                    reveals.append(f"riga {r} -> colonna {fog_c[0]}")
                    fog_c.pop(0)
                    changed = True
        for c in range(cols):
            if c not in done_c and col_complete(c):
                done_c.add(c)
                if fog_r:
                    reveals.append(f"colonna {c} -> riga {fog_r[0]}")
                    fog_r.pop(0)
                    changed = True

    unknown = sum(v is None for row in grid for v in row)
    wrong = sum(grid[r][c] is not None and grid[r][c] != solution[r][c]
                for r in range(rows) for c in range(cols))
    return unknown, wrong, reveals


def preview(matrix):
    return "\n".join("    " + "".join("#" if v else "." for v in row) for row in matrix)


def check_picross(p, verbose):
    matrix = [[int(v) for v in row] for row in p["solution_matrix"]]
    fog = p.get("fog", {})
    unknown, wrong, reveals = solve_by_logic(matrix, fog.get("rows", []), fog.get("cols", []))
    size = f"{len(matrix)}x{len(matrix[0])}"
    nfog = len(fog.get("rows", [])) + len(fog.get("cols", []))
    fog_txt = f", nebbia su {nfog} linee" if nfog else ""
    if unknown == 0 and wrong == 0:
        print(f"  OK    {p['puzzle_id']} (picross {size}{fog_txt})")
        if verbose and reveals:
            print("        " + "; ".join(reveals))
        return True
    print(f"  ERRORE {p['puzzle_id']} (picross {size}{fog_txt}): {unknown} celle non deducibili per logica")
    print(preview(matrix))
    return False


# =====================================================================
# SIGILLO RUNICO (sudoku)
# =====================================================================
def sudoku_units(n, br, bc):
    units = [[(r, c) for c in range(n)] for r in range(n)]
    units += [[(r, c) for r in range(n)] for c in range(n)]
    units += [[(r, c) for r in range(R, R + br) for c in range(C, C + bc)]
              for R in range(0, n, br) for C in range(0, n, bc)]
    peers = {(r, c): set() for r in range(n) for c in range(n)}
    for u in units:
        for cell in u:
            peers[cell].update(x for x in u if x != cell)
    return units, peers


def count_solutions(grid, n, peers, limit=2):
    g = [row[:] for row in grid]
    found = [0]

    def rec():
        if found[0] >= limit:
            return
        best = None
        for r in range(n):
            for c in range(n):
                if g[r][c] < 0:
                    opts = [v for v in range(n) if all(g[pr][pc] != v for pr, pc in peers[(r, c)])]
                    if best is None or len(opts) < len(best[2]):
                        best = (r, c, opts)
        if best is None:
            found[0] += 1
            return
        r, c, opts = best
        for v in opts:
            g[r][c] = v
            rec()
            g[r][c] = -1

    rec()
    return found[0]


def solve_with_singles(grid, n, units, peers):
    """Solo singoli nudi e nascosti. Restituisce (griglia, numero di passi)."""
    g = [row[:] for row in grid]
    steps = 0
    while True:
        cand = {}
        for r in range(n):
            for c in range(n):
                if g[r][c] < 0:
                    cand[(r, c)] = {v for v in range(n)} - {g[pr][pc] for pr, pc in peers[(r, c)]}
        if not cand:
            return g, steps
        move = None
        for cell, s in cand.items():
            if len(s) == 1:
                move = (cell, next(iter(s)))
                break
        if move is None:
            for u in units:
                for v in range(n):
                    spots = [cell for cell in u if cell in cand and v in cand[cell]]
                    if len(spots) == 1:
                        move = (spots[0], v)
                        break
                if move:
                    break
        if move is None:
            return g, steps
        (r, c), v = move
        g[r][c] = v
        steps += 1


def check_rune_sudoku(p, verbose):
    pid = p["puzzle_id"]
    n = int(p["size"])
    br, bc = (int(x) for x in p["box"])
    sol = [[int(v) for v in row] for row in p["solution"]]
    giv = [[int(v) for v in row] for row in p["givens"]]
    problems = []
    if br * bc != n:
        problems.append(f"riquadri {br}x{bc} incompatibili con {n}x{n}")
    if len(p.get("runes", [])) != n:
        problems.append(f"servono {n} rune, ce ne sono {len(p.get('runes', []))}")
    units, peers = sudoku_units(n, br, bc)
    for u in units:
        if sorted(sol[r][c] for r, c in u) != list(range(n)):
            problems.append("la soluzione ripete una runa in una riga, colonna o riquadro")
            break
    for r in range(n):
        for c in range(n):
            if giv[r][c] >= 0 and giv[r][c] != sol[r][c]:
                problems.append(f"runa data in [{r},{c}] diversa dalla soluzione")
    if not problems:
        nsol = count_solutions(giv, n, peers)
        if nsol != 1:
            problems.append("soluzione non unica" if nsol > 1 else "nessuna soluzione")
        else:
            g, steps = solve_with_singles(giv, n, units, peers)
            if g != sol:
                left = sum(v < 0 for row in g for v in row)
                problems.append(f"{left} caselle non deducibili con i soli singoli (serve tentare)")
    givens = sum(v >= 0 for row in giv for v in row)
    if problems:
        print(f"  ERRORE {pid} (sigillo runico {n}x{n}): " + "; ".join(problems))
        return False
    print(f"  OK    {pid} (sigillo runico {n}x{n}, {givens} rune date, {n * n - givens} da trovare)")
    return True


# =====================================================================
# CIME AGGROVIGLIATE (frecce che scivolano fuori)
# =====================================================================
def head_dir(cells):
    (r1, c1), (r2, c2) = cells[-2], cells[-1]
    return r2 - r1, c2 - c1


def ray(cells, rows, cols):
    dr, dc = head_dir(cells)
    r, c = cells[-1]
    out = []
    while True:
        r, c = r + dr, c + dc
        if not (0 <= r < rows and 0 <= c < cols):
            return out
        out.append((r, c))


def arrows_layers(lines, rows, cols):
    """Rimozione a strati: a ogni turno escono tutte le linee libere.
    Restituisce (strati, linee rimaste bloccate)."""
    alive = set(range(len(lines)))
    layers = []
    while alive:
        occ = {cell for i in alive for cell in lines[i]}
        free = [i for i in sorted(alive) if all(cell not in occ for cell in ray(lines[i], rows, cols))]
        if not free:
            return layers, sorted(alive)
        layers.append(free)
        alive -= set(free)
    return layers, []


def check_arrows(p, verbose):
    pid = p["puzzle_id"]
    rows, cols = int(p["grid_size"]["rows"]), int(p["grid_size"]["cols"])
    lines = [[tuple(int(v) for v in cell) for cell in l["cells"]] for l in p["lines"]]
    problems = []
    used = {}
    for i, cells in enumerate(lines):
        if len(cells) < 2:
            problems.append(f"linea {i}: meno di 2 celle")
            continue
        for k, (r, c) in enumerate(cells):
            if not (0 <= r < rows and 0 <= c < cols):
                problems.append(f"linea {i}: cella [{r},{c}] fuori dalla griglia")
            if (r, c) in used:
                problems.append(f"cella [{r},{c}] usata dalle linee {used[(r, c)]} e {i}")
            used[(r, c)] = i
            if k and abs(cells[k - 1][0] - r) + abs(cells[k - 1][1] - c) != 1:
                problems.append(f"linea {i}: salto tra {cells[k - 1]} e {(r, c)}")
    if problems:
        print(f"  ERRORE {pid} (cime {rows}x{cols}): " + "; ".join(problems))
        return False
    layers, stuck = arrows_layers(lines, rows, cols)
    if stuck:
        print(f"  ERRORE {pid} (cime {rows}x{cols}): le linee {stuck} si bloccano a vicenda")
        return False
    blocked = len(lines) - len(layers[0])
    print(f"  OK    {pid} (cime {rows}x{cols}, {len(lines)} linee, {len(used)}/{rows * cols} caselle, "
          f"{blocked} bloccate all'inizio, profondità {len(layers)})")
    if verbose:
        print("        strati: " + " | ".join(",".join(map(str, l)) for l in layers))
    return True


# =====================================================================
CHECKS = {"picross": check_picross, "rune_sudoku": check_rune_sudoku, "arrows": check_arrows}


def validate_file(path, verbose=False):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    ok = True
    print(f"\n{path}  ({data.get('case_id', '?')})")
    for p in data.get("puzzles", []):
        kind = p.get("type", "picross")
        check = CHECKS.get(kind)
        if check is None:
            print(f"  ERRORE {p.get('puzzle_id', '?')}: tipo '{kind}' sconosciuto")
            ok = False
            continue
        ok = check(p, verbose) and ok
    return ok


def main(args):
    verbose = "-v" in args
    args = [a for a in args if a != "-v"]
    if not args:
        print(__doc__)
        return 2
    files = []
    for a in args:
        p = Path(a)
        files.extend(sorted(p.glob("*.json")) if p.is_dir() else [p])
    results = [validate_file(f, verbose) for f in files]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
