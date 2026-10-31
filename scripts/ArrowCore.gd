class_name ArrowCore
extends Node

## Motore logico delle Cime Aggrovigliate (GDD #07): un puzzle a frecce che scivolano fuori.
## Ogni linea è una cima (o catena) di celle adiacenti che termina con una punta (l'ultima cella).
## Toccata, scivola come un serpente nella direzione della punta: la punta avanza in linea retta
## e il corpo la segue fino a uscire dalla griglia. Se sulla traiettoria della punta c'è
## un'altra linea, la cima urta e torna indietro: -1 Concentrazione (GDD #04, niente Game Over).
##
## Togliere una linea non blocca mai le altre: il puzzle non si può "rovinare" e non serve l'Annulla.
## Interfaccia comune agli altri core: puzzle_solved, concentration_depleted, get_stars(),
## register_assist(), apply_corrupted_ink(), to_dict(), load_state(), is_damaged, used_corrupted_ink.

signal line_removed(index: int)
## La cima urta: blocker = linea colpita, distance = celle percorse prima dell'urto.
signal line_blocked(index: int, blocker: int, distance: int, hp_remaining: int)
signal concentration_depleted
signal puzzle_solved

var rows: int = 0
var cols: int = 0
var lines: Array = []          # Array di Array[Vector2i] (riga, colonna); la punta è l'ultima
var removed: Array = []        # bool per linea

var max_hp: int = 3
var hp_concentration: int = 3
var errors_count: int = 0
var assists_used: int = 0
var is_completed: bool = false
var is_damaged: bool = false
var used_corrupted_ink: bool = false

var _occupant: Dictionary = {}   # Vector2i -> indice della linea che occupa la cella


# =====================================================================
# 1. INIZIALIZZAZIONE
# =====================================================================
## puzzle: il dizionario del JSON del caso (grid_size, lines, max_hp).
func setup_from_puzzle(puzzle: Dictionary) -> void:
	setup_puzzle(int(puzzle["grid_size"]["rows"]), int(puzzle["grid_size"]["cols"]),
			puzzle["lines"], int(puzzle.get("max_hp", 3)))


## line_data: [{ "cells": [[r, c], ...] }, ...] oppure direttamente [[[r, c], ...], ...]
func setup_puzzle(n_rows: int, n_cols: int, line_data: Array, initial_hp: int = 3) -> void:
	rows = n_rows
	cols = n_cols
	lines = []
	removed = []
	for entry in line_data:
		var raw: Array = entry["cells"] if entry is Dictionary else entry
		var cells: Array[Vector2i] = []
		for cell in raw:
			cells.append(Vector2i(int(cell[0]), int(cell[1])))
		lines.append(cells)
		removed.append(false)
	max_hp = initial_hp
	hp_concentration = initial_hp
	errors_count = 0
	assists_used = 0
	is_completed = false
	is_damaged = false
	used_corrupted_ink = false
	_rebuild_occupancy()


func _rebuild_occupancy() -> void:
	_occupant.clear()
	for i in lines.size():
		if removed[i]:
			continue
		for cell in lines[i]:
			_occupant[cell] = i


# =====================================================================
# 2. GEOMETRIA
# =====================================================================
## Direzione della punta: Vector2i(delta_riga, delta_colonna).
func head_dir(index: int) -> Vector2i:
	var cells: Array = lines[index]
	return cells[-1] - cells[-2]


## Celle dalla punta (esclusa) fino al bordo, nella direzione della punta.
func ray(index: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var d := head_dir(index)
	var p: Vector2i = lines[index][-1] + d
	while p.x >= 0 and p.y >= 0 and p.x < rows and p.y < cols:
		out.append(p)
		p += d
	return out


## Prima linea che blocca la traiettoria: Vector2i(indice, distanza in celle), (-1, -1) se libera.
func first_blocker(index: int) -> Vector2i:
	var path := ray(index)
	for k in path.size():
		var occ: int = _occupant.get(path[k], -1)
		if occ >= 0 and occ != index:
			return Vector2i(occ, k)
	return Vector2i(-1, -1)


func is_free(index: int) -> bool:
	return not removed[index] and first_blocker(index).x < 0


func line_at(cell: Vector2i) -> int:
	return _occupant.get(cell, -1)


func remaining() -> int:
	var n := 0
	for r in removed:
		if not r:
			n += 1
	return n


# =====================================================================
# 3. MOSSE DEL GIOCATORE
# =====================================================================
## Tocco su una linea. Restituisce true se la linea è uscita.
func try_remove(index: int) -> bool:
	if is_completed or index < 0 or index >= lines.size() or removed[index]:
		return false
	var block := first_blocker(index)
	if block.x >= 0:
		errors_count += 1
		if hp_concentration > 0:
			hp_concentration -= 1
			if hp_concentration == 0 and not is_damaged:
				is_damaged = true
				concentration_depleted.emit()
		line_blocked.emit(index, block.x, block.y, hp_concentration)
		return false
	_remove(index)
	return true


## Tocco su una cella: agisce sulla linea che la occupa (-1 = nessuna).
func tap_cell(cell: Vector2i) -> int:
	var index := line_at(cell)
	if index >= 0:
		try_remove(index)
	return index


func _remove(index: int) -> void:
	removed[index] = true
	for cell in lines[index]:
		_occupant.erase(cell)
	line_removed.emit(index)
	if remaining() == 0 and not is_completed:
		is_completed = true
		puzzle_solved.emit()


# =====================================================================
# 4. AIUTI E INCHIOSTRO CORROTTO
# =====================================================================
func register_assist() -> void:
	assists_used += 1


## Una linea che può uscire subito (-1 se non ce ne sono: impossibile con puzzle validati).
## Preferisce quella che ne sblocca di più, così l'aiuto insegna qualcosa.
func find_hint() -> int:
	var best := -1
	var best_score := -1
	for i in lines.size():
		if not is_free(i):
			continue
		var score := 0
		for j in lines.size():
			if j != i and not removed[j] and first_blocker(j).x == i:
				score += 1
		if score > best_score:
			best = i
			best_score = score
	return best


## Aiuto: indica una linea libera (la UI la evidenzia). Toglie la terza stella.
func use_hint() -> int:
	if is_completed:
		return -1
	var i := find_hint()
	if i >= 0:
		register_assist()
	return i


## Inchiostro Corrotto: tutte le cime si sciolgono. SOLO dopo il pop-up Patto Oscuro.
func apply_corrupted_ink() -> void:
	if is_completed:
		return
	used_corrupted_ink = true
	var guard := 0
	while remaining() > 0 and guard < lines.size() * lines.size() + 1:
		guard += 1
		var progressed := false
		for i in lines.size():
			if is_free(i):
				_remove(i)
				progressed = true
		if not progressed:   # puzzle non valido: si scioglie comunque tutto
			for i in lines.size():
				if not removed[i]:
					_remove(i)


# =====================================================================
# 5. STELLE E SALVATAGGIO
# =====================================================================
func get_stars() -> int:
	if not is_completed or used_corrupted_ink:
		return 0
	if errors_count > 0:
		return 1
	return 2 if assists_used > 0 else 3


func to_dict() -> Dictionary:
	var gone: Array = []
	for i in removed.size():
		if removed[i]:
			gone.append(i)
	return {
		"kind": "arrows",
		"removed": gone,
		"hp": hp_concentration,
		"max_hp": max_hp,
		"errors": errors_count,
		"assists": assists_used,
		"damaged": is_damaged,
		"corrupted": used_corrupted_ink,
		"completed": is_completed,
	}


## Da chiamare DOPO setup_puzzle(). Le linee si rimettono in gioco solo se il salvataggio è compatibile.
func load_state(state: Dictionary) -> void:
	if state.get("kind", "arrows") != "arrows":
		push_warning("ArrowCore: salvataggio non compatibile con il puzzle, ignorato.")
		return
	for i in removed.size():
		removed[i] = false
	for v in state.get("removed", []):
		var i := int(v)
		if i >= 0 and i < removed.size():
			removed[i] = true
	max_hp = int(state.get("max_hp", max_hp))
	hp_concentration = int(state.get("hp", max_hp))
	errors_count = int(state.get("errors", 0))
	assists_used = int(state.get("assists", 0))
	is_damaged = bool(state.get("damaged", false))
	used_corrupted_ink = bool(state.get("corrupted", false))
	is_completed = bool(state.get("completed", false)) or remaining() == 0
	_rebuild_occupancy()
