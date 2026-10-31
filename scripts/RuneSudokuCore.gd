class_name RuneSudokuCore
extends Node

## Motore logico del Sigillo Runico (GDD #07): un sudoku classico con rune al posto dei numeri.
## Ogni runa compare una sola volta in ogni riga, colonna e riquadro.
## Il "Model" del pattern MVC: nessun riferimento a nodi grafici, comunica solo con segnali.
##
## Stesse regole del Picross (GDD #04):
##   - validazione istantanea: una runa sbagliata costa 1 Concentrazione e NON viene posata
##     (nel sudoku bloccare una casella sbagliata non avrebbe senso)
##   - Concentrazione a 0: nessun Game Over, si continua e la prova diventa "Danneggiata"
##   - stelle: 3 senza errori né aiuti, 2 con aiuti, 1 con errori, 0 con l'Inchiostro Corrotto
## Interfaccia comune agli altri core: puzzle_solved, concentration_depleted, get_stars(),
## register_assist(), apply_corrupted_ink(), to_dict(), load_state(), is_damaged, used_corrupted_ink.
##
## Le annotazioni (rune a matita) sono libere: non vengono validate e non costano nulla.

signal cell_changed(row: int, col: int, rune: int)      # rune = -1: casella vuota
signal notes_changed(row: int, col: int)
signal error_committed(row: int, col: int, rune: int, hp_remaining: int)
signal concentration_depleted
signal rune_completed(rune: int)                         # la runa è stata posata in tutte le sue caselle
signal puzzle_solved

const EMPTY := -1

var size: int = 0
var box_rows: int = 2
var box_cols: int = 2
var solution: Array = []        # size x size, indici di runa 0..size-1
var givens: Array = []          # size x size, -1 = vuota
var player: Array = []          # size x size, -1 = vuota (contiene anche le rune date)
var notes: Array = []           # size x size, maschera di bit: bit v = runa v annotata

var max_hp: int = 3
var hp_concentration: int = 3
var errors_count: int = 0
var assists_used: int = 0
var is_completed: bool = false
var is_damaged: bool = false
var used_corrupted_ink: bool = false


# =====================================================================
# 1. INIZIALIZZAZIONE
# =====================================================================
## puzzle: il dizionario del JSON del caso (size, box, solution, givens, max_hp).
func setup_from_puzzle(puzzle: Dictionary) -> void:
	setup_puzzle(puzzle["solution"], puzzle["givens"], puzzle["box"], int(puzzle.get("max_hp", 3)))


func setup_puzzle(sol: Array, giv: Array, box: Array, initial_hp: int = 3) -> void:
	size = sol.size()
	box_rows = int(box[0])
	box_cols = int(box[1])
	solution = []
	givens = []
	player = []
	notes = []
	for r in size:
		var srow: Array = []
		var grow: Array = []
		var prow: Array = []
		var nrow: Array = []
		for c in size:
			srow.append(int(sol[r][c]))
			grow.append(int(giv[r][c]))
			prow.append(int(giv[r][c]))
			nrow.append(0)
		solution.append(srow)
		givens.append(grow)
		player.append(prow)
		notes.append(nrow)
	max_hp = initial_hp
	hp_concentration = initial_hp
	errors_count = 0
	assists_used = 0
	is_completed = false
	is_damaged = false
	used_corrupted_ink = false


func is_given(r: int, c: int) -> bool:
	return givens[r][c] != EMPTY


func is_filled(r: int, c: int) -> bool:
	return player[r][c] != EMPTY


# =====================================================================
# 2. MOSSE DEL GIOCATORE
# =====================================================================
## Posa una runa. Restituisce true se la runa è giusta (e quindi posata).
## Una runa sbagliata costa 1 Concentrazione e la casella resta vuota.
func place_rune(r: int, c: int, rune: int) -> bool:
	if is_completed or not _in_bounds(r, c) or rune < 0 or rune >= size:
		return false
	if is_filled(r, c):
		return false   # rune date e rune già posate (sempre giuste) non si cambiano
	if solution[r][c] != rune:
		_register_error(r, c, rune)
		return false
	player[r][c] = rune
	cell_changed.emit(r, c, rune)
	_clear_note_in_peers(r, c, rune)
	if notes[r][c] != 0:
		notes[r][c] = 0
		notes_changed.emit(r, c)
	if count_placed(rune) == size:
		rune_completed.emit(rune)
	_check_solved()
	return true


## Annotazione a matita: aggiunge o toglie la runa dalla casella vuota.
func toggle_note(r: int, c: int, rune: int) -> void:
	if is_completed or not _in_bounds(r, c) or is_filled(r, c) or rune < 0 or rune >= size:
		return
	notes[r][c] = notes[r][c] ^ (1 << rune)
	notes_changed.emit(r, c)


func has_note(r: int, c: int, rune: int) -> bool:
	return (notes[r][c] >> rune) & 1 == 1


func clear_notes(r: int, c: int) -> void:
	if notes[r][c] != 0:
		notes[r][c] = 0
		notes_changed.emit(r, c)


func _register_error(r: int, c: int, rune: int) -> void:
	errors_count += 1
	if hp_concentration > 0:
		hp_concentration -= 1
		if hp_concentration == 0 and not is_damaged:
			is_damaged = true
			concentration_depleted.emit()
	error_committed.emit(r, c, rune, hp_concentration)


## Posando una runa, sparisce la stessa annotazione nelle caselle della stessa riga/colonna/riquadro.
func _clear_note_in_peers(r: int, c: int, rune: int) -> void:
	for p in peers(r, c):
		if has_note(p.x, p.y, rune):
			notes[p.x][p.y] = notes[p.x][p.y] & ~(1 << rune)
			notes_changed.emit(p.x, p.y)


# =====================================================================
# 3. AIUTI E INCHIOSTRO CORROTTO
# =====================================================================
func register_assist() -> void:
	assists_used += 1


## Rune ancora possibili per una casella vuota (in base alle rune già posate).
func candidates(r: int, c: int) -> Array:
	if is_filled(r, c):
		return []
	var used := {}
	for p in peers(r, c):
		if player[p.x][p.y] != EMPTY:
			used[player[p.x][p.y]] = true
	var out: Array = []
	for v in size:
		if not used.has(v):
			out.append(v)
	return out


## Una mossa deducibile senza tentare: Vector3i(riga, colonna, runa), oppure (-1, -1, -1).
## Prima i "singoli nudi" (una sola runa possibile), poi i "singoli nascosti"
## (una runa che in una riga/colonna/riquadro può andare in una sola casella).
func find_hint() -> Vector3i:
	for r in size:
		for c in size:
			if not is_filled(r, c):
				var cand := candidates(r, c)
				if cand.size() == 1:
					return Vector3i(r, c, cand[0])
	for unit in units():
		for v in size:
			var spots: Array = []
			var present := false
			for cell in unit:
				if player[cell.x][cell.y] == v:
					present = true
					break
				if not is_filled(cell.x, cell.y) and v in candidates(cell.x, cell.y):
					spots.append(cell)
			if not present and spots.size() == 1:
				return Vector3i(spots[0].x, spots[0].y, v)
	# Per sicurezza (non dovrebbe servire con puzzle validati): la prima casella vuota
	for r in size:
		for c in size:
			if not is_filled(r, c):
				return Vector3i(r, c, solution[r][c])
	return Vector3i(-1, -1, -1)


## Aiuto: posa una runa deducibile. Toglie la terza stella (GDD #04), non tocca i finali.
func use_hint() -> Vector3i:
	if is_completed:
		return Vector3i(-1, -1, -1)
	var h := find_hint()
	if h.x >= 0:
		register_assist()
		place_rune(h.x, h.y, h.z)
	return h


## Inchiostro Corrotto: completa il sigillo. Da chiamare SOLO dopo il pop-up Patto Oscuro.
func apply_corrupted_ink() -> void:
	if is_completed:
		return
	used_corrupted_ink = true
	for r in size:
		for c in size:
			if not is_filled(r, c):
				player[r][c] = solution[r][c]
				notes[r][c] = 0
				cell_changed.emit(r, c, player[r][c])
	_check_solved()


# =====================================================================
# 4. VITTORIA E STELLE
# =====================================================================
func _check_solved() -> void:
	if is_completed:
		return
	for r in size:
		for c in size:
			if player[r][c] != solution[r][c]:
				return
	is_completed = true
	puzzle_solved.emit()


func get_stars() -> int:
	if not is_completed or used_corrupted_ink:
		return 0
	if errors_count > 0:
		return 1
	return 2 if assists_used > 0 else 3


## Quante caselle contengono già la runa (date + posate).
func count_placed(rune: int) -> int:
	var n := 0
	for r in size:
		for c in size:
			if player[r][c] == rune:
				n += 1
	return n


# =====================================================================
# 5. SALVATAGGIO / CARICAMENTO
# =====================================================================
## La soluzione e le rune date NON vengono salvate: arrivano dal CaseLoader.
func to_dict() -> Dictionary:
	return {
		"kind": "rune_sudoku",
		"player": player.duplicate(true),
		"notes": notes.duplicate(true),
		"hp": hp_concentration,
		"max_hp": max_hp,
		"errors": errors_count,
		"assists": assists_used,
		"damaged": is_damaged,
		"corrupted": used_corrupted_ink,
		"completed": is_completed,
	}


## Da chiamare DOPO setup_puzzle(). Converte in int (JSON restituisce float).
func load_state(state: Dictionary) -> void:
	var saved: Array = state.get("player", [])
	if saved.size() != size or state.get("kind", "rune_sudoku") != "rune_sudoku":
		push_warning("RuneSudokuCore: salvataggio non compatibile con il puzzle, ignorato.")
		return
	for r in size:
		for c in size:
			var v := int(saved[r][c])
			# una casella data resta quella del puzzle; una posata deve essere giusta
			if is_given(r, c):
				continue
			player[r][c] = v if v == solution[r][c] else EMPTY
	var saved_notes: Array = state.get("notes", [])
	if saved_notes.size() == size:
		for r in size:
			for c in size:
				notes[r][c] = int(saved_notes[r][c])
	max_hp = int(state.get("max_hp", max_hp))
	hp_concentration = int(state.get("hp", max_hp))
	errors_count = int(state.get("errors", 0))
	assists_used = int(state.get("assists", 0))
	is_damaged = bool(state.get("damaged", false))
	used_corrupted_ink = bool(state.get("corrupted", false))
	is_completed = bool(state.get("completed", false))


# =====================================================================
# 6. GEOMETRIA
# =====================================================================
## Le caselle che "vedono" (r, c): stessa riga, colonna o riquadro, esclusa (r, c).
@warning_ignore("integer_division")
func peers(r: int, c: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var seen := {}
	for i in size:
		for cell in [Vector2i(r, i), Vector2i(i, c)]:
			if cell != Vector2i(r, c) and not seen.has(cell):
				seen[cell] = true
				out.append(cell)
	var br := (r / box_rows) * box_rows
	var bc := (c / box_cols) * box_cols
	for rr in range(br, br + box_rows):
		for cc in range(bc, bc + box_cols):
			var cell := Vector2i(rr, cc)
			if cell != Vector2i(r, c) and not seen.has(cell):
				seen[cell] = true
				out.append(cell)
	return out


## Tutte le righe, colonne e riquadri come liste di Vector2i.
func units() -> Array:
	var out: Array = []
	for i in size:
		var row: Array[Vector2i] = []
		var col: Array[Vector2i] = []
		for j in size:
			row.append(Vector2i(i, j))
			col.append(Vector2i(j, i))
		out.append(row)
		out.append(col)
	for br in range(0, size, box_rows):
		for bc in range(0, size, box_cols):
			var box: Array[Vector2i] = []
			for r in range(br, br + box_rows):
				for c in range(bc, bc + box_cols):
					box.append(Vector2i(r, c))
			out.append(box)
	return out


func _in_bounds(r: int, c: int) -> bool:
	return r >= 0 and c >= 0 and r < size and c < size
