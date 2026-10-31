class_name PicrossCore
extends Node

## Motore logico del Picross (il "Model" del pattern MVC).
## Nessun riferimento a nodi grafici: comunica solo tramite segnali.
## v2: celle d'errore bloccate, stato Danneggiata, linee completate/annullate,
##     Auto-Cross, Undo a gesti, Stelle, salvataggio/caricamento dello stato.
## v3: Nebbia Arcanica (GDD #06): i numeri guida di alcune linee sono nascosti.
##     Ogni riga completata dirada la prima colonna annebbiata, ogni colonna completata
##     la prima riga annebbiata (nell'ordine dei dati del caso). Alla vittoria si dirada tutta.

# --- Segnali verso la UI ---
signal cell_changed(row: int, col: int, new_state: int)
signal row_completed(row: int)
signal row_uncompleted(row: int)        # la riga non è più completa (es. dopo un Undo)
signal col_completed(col: int)
signal col_uncompleted(col: int)
signal puzzle_solved
signal error_committed(row: int, col: int, hp_remaining: int)
signal concentration_depleted           # la prova diventa "Danneggiata" (niente Game Over)
signal undo_availability_changed(can_undo: bool)
signal fog_cleared(is_row: bool, index: int)   # Nebbia Arcanica: numeri guida di nuovo visibili

enum CellState { EMPTY, FILLED, MARKED_X }

const MAX_UNDO_STEPS: int = 200

## Al completamento di una riga/colonna, le celle vuote rimaste ricevono una 'X' (GDD #03)
@export var auto_cross_completed_lines: bool = true

# --- Stato del puzzle ---
var rows: int = 0
var cols: int = 0
var solution_matrix: Array = []   # 0 = vuoto, 1 = pieno
var player_matrix: Array = []     # valori di CellState

var max_hp: int = 3
var hp_concentration: int = 3
var errors_count: int = 0         # errori totali (anche dopo HP a 0): serve per le stelle
var assists_used: int = 0         # aiuti dello Skill Tree / consumabili usati
var is_completed: bool = false
var is_damaged: bool = false      # true quando la Concentrazione arriva a 0
var used_corrupted_ink: bool = false  # Patto Oscuro accettato: il punteggio morale lo gestisce la campagna

var fog_rows: Array = []          # righe con numeri guida annebbiati, in ordine di rivelazione
var fog_cols: Array = []
var _fog_spent: Dictionary = {}   # "r3" / "c5": linee che hanno già diradato la nebbia (niente trucchi con Annulla)

var _locked: Dictionary = {}      # Vector2i(r, c) -> true: 'X' di errore, immodificabili
var _done_rows: Dictionary = {}   # righe attualmente complete
var _done_cols: Dictionary = {}

# --- Undo: ogni voce è un "gesto" (tap o drag) = lista di [r, c, stato_precedente] ---
var _undo_stack: Array = []
var _batch: Array = []
var _batch_open: bool = false


# =====================================================================
# 1. INIZIALIZZAZIONE
# =====================================================================
func setup_puzzle(sol_matrix: Array, initial_hp: int = 3) -> void:
	solution_matrix = sol_matrix
	rows = solution_matrix.size()
	cols = solution_matrix[0].size() if rows > 0 else 0
	max_hp = initial_hp
	hp_concentration = initial_hp
	errors_count = 0
	assists_used = 0
	is_completed = false
	is_damaged = false
	used_corrupted_ink = false
	_locked.clear()
	_undo_stack.clear()
	_batch.clear()
	_batch_open = false
	fog_rows.clear()
	fog_cols.clear()
	_fog_spent.clear()

	player_matrix.clear()
	for r in rows:
		var row_array: Array = []
		for c in cols:
			row_array.append(CellState.EMPTY)
		player_matrix.append(row_array)

	_rebuild_line_status()


## Nebbia Arcanica: da chiamare dopo setup_puzzle() (e prima di load_state()).
func setup_fog(rows_list: Array, cols_list: Array) -> void:
	fog_rows.clear()
	fog_cols.clear()
	for r in rows_list:
		if int(r) >= 0 and int(r) < rows:
			fog_rows.append(int(r))
	for c in cols_list:
		if int(c) >= 0 and int(c) < cols:
			fog_cols.append(int(c))


func is_row_fogged(r: int) -> bool:
	return r in fog_rows


func is_col_fogged(c: int) -> bool:
	return c in fog_cols


func has_fog() -> bool:
	return not fog_rows.is_empty() or not fog_cols.is_empty()


func _clear_next_fog(on_rows: bool) -> void:
	var list := fog_rows if on_rows else fog_cols
	if list.is_empty():
		return
	var index: int = list.pop_front()
	fog_cleared.emit(on_rows, index)


func _clear_all_fog() -> void:
	while not fog_rows.is_empty():
		_clear_next_fog(true)
	while not fog_cols.is_empty():
		_clear_next_fog(false)


# =====================================================================
# 2. MOSSE DEL GIOCATORE
# =====================================================================
## Apre un gesto: tutte le modifiche fino a end_action() si annullano con un solo Undo.
## La UI lo chiama all'inizio di un tap/drag. Se non lo fa, ogni interact_cell è un gesto a sé.
func begin_action() -> void:
	if _batch_open:
		end_action()
	_batch.clear()
	_batch_open = true


func end_action() -> void:
	if not _batch_open:
		return
	_batch_open = false
	if _batch.is_empty():
		return
	_undo_stack.append(_batch.duplicate())
	if _undo_stack.size() > MAX_UNDO_STEPS:
		_undo_stack.pop_front()
	_batch.clear()
	undo_availability_changed.emit(true)


func interact_cell(r: int, c: int, target_state: CellState) -> void:
	if is_completed or not _in_bounds(r, c):
		return
	var own_batch := not _batch_open
	if own_batch:
		begin_action()
	_interact(r, c, target_state)
	if own_batch:
		end_action()


func _interact(r: int, c: int, target_state: CellState) -> void:
	# Le 'X' generate da un errore sono definitive: nessun doppio danno, nessun "aggiramento"
	if _locked.has(Vector2i(r, c)):
		return

	var current: int = player_matrix[r][c]
	var new_state: CellState = target_state if current != target_state else CellState.EMPTY

	# Errore: tentativo di riempire una cella che nella soluzione è vuota
	if new_state == CellState.FILLED and solution_matrix[r][c] == 0:
		_register_error(r, c)
		return

	_set_cell(r, c, new_state)
	_update_lines(r, c)
	_check_puzzle_status()


func _register_error(r: int, c: int) -> void:
	errors_count += 1
	if hp_concentration > 0:
		hp_concentration -= 1
		if hp_concentration == 0 and not is_damaged:
			is_damaged = true
			concentration_depleted.emit()
	# La 'X' d'errore non entra nello storico Undo: l'errore non si cancella
	player_matrix[r][c] = CellState.MARKED_X
	_locked[Vector2i(r, c)] = true
	cell_changed.emit(r, c, CellState.MARKED_X)
	error_committed.emit(r, c, hp_concentration)


## Da chiamare quando il giocatore usa un aiuto (Prescienza Logica, Monocolo, ecc.).
## Gli aiuti normali tolgono solo la terza stella: NESSUN effetto sui finali.
func register_assist() -> void:
	assists_used += 1


## Inchiostro Corrotto: risolve all'istante l'intera griglia.
## Va chiamato SOLO dopo che il giocatore ha confermato il pop-up "Patto Oscuro".
## Il Core segna solo il flag; il +1 verso il Finale Oscuro lo assegna lo stato di campagna.
func apply_corrupted_ink() -> void:
	if is_completed:
		return
	used_corrupted_ink = true
	if _batch_open:
		end_action()
	for r in rows:
		for c in cols:
			if _locked.has(Vector2i(r, c)):
				continue
			var target := CellState.FILLED if solution_matrix[r][c] == 1 else CellState.MARKED_X
			_set_cell(r, c, target)
	for r in rows:
		_update_row(r)
	for c in cols:
		_update_col(c)
	_check_puzzle_status()


# =====================================================================
# 3. UNDO
# =====================================================================
func can_undo() -> bool:
	return not is_completed and not _undo_stack.is_empty()


func undo() -> bool:
	if not can_undo():
		return false
	if _batch_open:
		end_action()
	var batch: Array = _undo_stack.pop_back()
	var touched_rows := {}
	var touched_cols := {}
	# Ripristino in ordine inverso; le celle bloccate da un errore restano come sono
	for i in range(batch.size() - 1, -1, -1):
		var r: int = batch[i][0]
		var c: int = batch[i][1]
		var prev: int = batch[i][2]
		if _locked.has(Vector2i(r, c)):
			continue
		player_matrix[r][c] = prev
		cell_changed.emit(r, c, prev)
		touched_rows[r] = true
		touched_cols[c] = true
	for r in touched_rows:
		_update_row(r)
	for c in touched_cols:
		_update_col(c)
	undo_availability_changed.emit(can_undo())
	return true


# =====================================================================
# 4. RIGHE / COLONNE COMPLETATE E VITTORIA
# =====================================================================
func _update_lines(r: int, c: int) -> void:
	_update_row(r)
	_update_col(c)


func _update_row(r: int) -> void:
	var complete := _row_complete(r)
	if complete and not _done_rows.has(r):
		_done_rows[r] = true
		if auto_cross_completed_lines:
			for c in cols:
				_auto_cross(r, c)
		row_completed.emit(r)
		if not _fog_spent.has("r%d" % r):   # riga completata: si dirada una colonna (linea ortogonale)
			_fog_spent["r%d" % r] = true
			_clear_next_fog(false)
	elif not complete and _done_rows.has(r):
		_done_rows.erase(r)
		row_uncompleted.emit(r)


func _update_col(c: int) -> void:
	var complete := _col_complete(c)
	if complete and not _done_cols.has(c):
		_done_cols[c] = true
		if auto_cross_completed_lines:
			for r in rows:
				_auto_cross(r, c)
		col_completed.emit(c)
		if not _fog_spent.has("c%d" % c):   # colonna completata: si dirada una riga
			_fog_spent["c%d" % c] = true
			_clear_next_fog(true)
	elif not complete and _done_cols.has(c):
		_done_cols.erase(c)
		col_uncompleted.emit(c)


func _row_complete(r: int) -> bool:
	for c in cols:
		if (solution_matrix[r][c] == 1) != (player_matrix[r][c] == CellState.FILLED):
			return false
	return true


func _col_complete(c: int) -> bool:
	for r in rows:
		if (solution_matrix[r][c] == 1) != (player_matrix[r][c] == CellState.FILLED):
			return false
	return true


func _auto_cross(r: int, c: int) -> void:
	if player_matrix[r][c] == CellState.EMPTY:
		_set_cell(r, c, CellState.MARKED_X)


## Ricalcola in silenzio quali linee sono complete (setup e caricamento salvataggio)
func _rebuild_line_status() -> void:
	_done_rows.clear()
	_done_cols.clear()
	for r in rows:
		if _row_complete(r):
			_done_rows[r] = true
	for c in cols:
		if _col_complete(c):
			_done_cols[c] = true


func _check_puzzle_status() -> void:
	if is_completed:
		return
	for r in rows:
		if not _row_complete(r):
			return
	is_completed = true
	_clear_all_fog()
	undo_availability_changed.emit(false)
	puzzle_solved.emit()


func is_row_done(r: int) -> bool:
	return _done_rows.has(r)


func is_col_done(c: int) -> bool:
	return _done_cols.has(c)


func is_locked(r: int, c: int) -> bool:
	return _locked.has(Vector2i(r, c))


# =====================================================================
# 5. STELLE (★ risolto / ★★ senza errori / ★★★ senza errori né aiuti)
#    Con l'Inchiostro Corrotto la griglia è risolta ma vale 0 stelle.
# =====================================================================
func get_stars() -> int:
	if not is_completed or used_corrupted_ink:
		return 0
	if errors_count > 0:
		return 1
	return 2 if assists_used > 0 else 3


# =====================================================================
# 6. SALVATAGGIO / CARICAMENTO (sessioni mobile "mordi e fuggi")
# =====================================================================
## Stato serializzabile in JSON. La soluzione NON viene salvata: arriva dal CaseLoader.
func to_dict() -> Dictionary:
	var locked_list: Array = []
	for key in _locked:
		locked_list.append([key.x, key.y])
	return {
		"player_matrix": player_matrix.duplicate(true),
		"hp": hp_concentration,
		"max_hp": max_hp,
		"errors": errors_count,
		"assists": assists_used,
		"damaged": is_damaged,
		"corrupted": used_corrupted_ink,
		"completed": is_completed,
		"locked": locked_list,
		"fog_rows": fog_rows.duplicate(),
		"fog_cols": fog_cols.duplicate(),
		"fog_spent": _fog_spent.keys(),
	}


## Da chiamare DOPO setup_puzzle() con la stessa soluzione, e PRIMA di collegare la UI.
## Converte esplicitamente in int: JSON.parse restituisce i numeri come float.
func load_state(state: Dictionary) -> void:
	var saved: Array = state.get("player_matrix", [])
	if saved.size() != rows:
		push_warning("PicrossCore: salvataggio non compatibile con il puzzle, ignorato.")
		return
	for r in rows:
		for c in cols:
			player_matrix[r][c] = int(saved[r][c])
	max_hp = int(state.get("max_hp", max_hp))
	hp_concentration = int(state.get("hp", max_hp))
	errors_count = int(state.get("errors", 0))
	assists_used = int(state.get("assists", 0))
	is_damaged = bool(state.get("damaged", false))
	used_corrupted_ink = bool(state.get("corrupted", false))
	is_completed = bool(state.get("completed", false))
	_locked.clear()
	for pair in state.get("locked", []):
		_locked[Vector2i(int(pair[0]), int(pair[1]))] = true
	if state.has("fog_rows") or state.has("fog_cols"):
		setup_fog(state.get("fog_rows", []), state.get("fog_cols", []))
		_fog_spent.clear()
		for key in state.get("fog_spent", []):
			_fog_spent[str(key)] = true
	_undo_stack.clear()
	_rebuild_line_status()


# =====================================================================
# 7. NUMERI GUIDA
# =====================================================================
func get_row_hints(r: int) -> Array[int]:
	var line: Array = []
	for c in cols:
		line.append(solution_matrix[r][c])
	return _hints_for_line(line)


func get_col_hints(c: int) -> Array[int]:
	var line: Array = []
	for r in rows:
		line.append(solution_matrix[r][c])
	return _hints_for_line(line)


func _hints_for_line(line: Array) -> Array[int]:
	var hints: Array[int] = []
	var count := 0
	for v in line:
		if v == 1:
			count += 1
		elif count > 0:
			hints.append(count)
			count = 0
	if count > 0:
		hints.append(count)
	if hints.is_empty():
		hints.append(0)
	return hints


# =====================================================================
# 8. UTILITY
# =====================================================================
func _in_bounds(r: int, c: int) -> bool:
	return r >= 0 and c >= 0 and r < rows and c < cols


## Scrive una cella, la registra nel gesto Undo aperto e notifica la UI.
func _set_cell(r: int, c: int, new_state: int) -> void:
	var prev: int = player_matrix[r][c]
	if prev == new_state:
		return
	player_matrix[r][c] = new_state
	if _batch_open:
		_batch.append([r, c, prev])
	cell_changed.emit(r, c, new_state)
