class_name CaseLoader
extends RefCounted

## Carica e VALIDA i file dei casi (res://data/cases/*.json).
## Un errore nei dati viene segnalato subito al caricamento, non a metà partita.
## Le matrici vengono convertite in int (JSON restituisce i numeri come float).
##
## Tipi di enigma (campo "type" del puzzle, GDD #07):
##   "picross"      (predefinito se manca) -> grid_size, solution_matrix, fog facoltativa
##   "rune_sudoku"  -> size, box [righe, colonne], runes, solution, givens (-1 = vuota)
##   "arrows"       -> grid_size, lines [{ "cells": [[r, c], ...] }], punta = ultima cella
##
## Uso:
##   var case_data := CaseLoader.load_case("res://data/cases/case_01.json")
##   var puzzle := CaseLoader.get_puzzle(case_data, "clue_poison_glass")
##   core.setup_puzzle(puzzle["solution_matrix"], 3)

const REQUIRED_CASE_KEYS := ["case_id", "title", "puzzles", "interrogation_phases"]
const REQUIRED_PUZZLE_KEYS := {
	"picross": ["puzzle_id", "grid_size", "solution_matrix", "reward_clue"],
	"rune_sudoku": ["puzzle_id", "size", "box", "runes", "solution", "givens", "reward_clue"],
	"arrows": ["puzzle_id", "grid_size", "lines", "reward_clue"],
}


static func load_case(file_path: String) -> Dictionary:
	if not FileAccess.file_exists(file_path):
		push_error("CaseLoader: file non trovato: %s" % file_path)
		return {}

	var json := JSON.new()
	var err := json.parse(FileAccess.get_file_as_string(file_path))
	if err != OK:
		push_error("CaseLoader: JSON non valido in %s, riga %d: %s"
				% [file_path, json.get_error_line(), json.get_error_message()])
		return {}

	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		push_error("CaseLoader: %s non contiene un oggetto JSON." % file_path)
		return {}

	var problems := validate_case(data)
	if not problems.is_empty():
		for p in problems:
			push_error("CaseLoader [%s]: %s" % [file_path, p])
		return {}
	return data


static func get_puzzle(case_data: Dictionary, puzzle_id: String) -> Dictionary:
	for puzzle in case_data.get("puzzles", []):
		if puzzle["puzzle_id"] == puzzle_id:
			return puzzle
	push_error("CaseLoader: puzzle '%s' non trovato." % puzzle_id)
	return {}


## Tipo di enigma del puzzle ("picross" se il campo manca: i casi vecchi restano validi).
static func puzzle_type(puzzle: Dictionary) -> String:
	return String(puzzle.get("type", "picross"))


## Restituisce l'elenco dei problemi trovati (vuoto = caso valido).
## Converte anche le matrici in int, modificando i dati in place.
static func validate_case(data: Dictionary) -> Array[String]:
	var problems: Array[String] = []
	for key in REQUIRED_CASE_KEYS:
		if not data.has(key):
			problems.append("manca la chiave '%s'" % key)
	if not problems.is_empty():
		return problems

	var clue_tags := {}
	for puzzle in data["puzzles"]:
		var pid: String = puzzle.get("puzzle_id", "?")
		var kind := puzzle_type(puzzle)
		if not REQUIRED_PUZZLE_KEYS.has(kind):
			problems.append("puzzle '%s': tipo '%s' sconosciuto" % [pid, kind])
			continue
		var missing := false
		for key in REQUIRED_PUZZLE_KEYS[kind]:
			if not puzzle.has(key):
				problems.append("puzzle '%s': manca '%s'" % [pid, key])
				missing = true
		if missing:
			continue
		match kind:
			"picross":
				_validate_picross(puzzle, pid, problems)
			"rune_sudoku":
				_validate_rune_sudoku(puzzle, pid, problems)
			"arrows":
				_validate_arrows(puzzle, pid, problems)

		for tag in puzzle.get("reward_clue", {}).get("tags", []):
			clue_tags[tag] = true

	# Ogni tag richiesto negli interrogatori deve esistere tra prove o testimonianze
	for phase in data["interrogation_phases"]:
		var granted = phase.get("grants_tag", "")
		if granted != "":
			clue_tags[granted] = true
	for phase in data["interrogation_phases"]:
		var needed: Array = []
		if phase.has("target_tag"):
			needed.append(phase["target_tag"])
		needed.append_array(phase.get("required_tags", []))
		for tag in needed:
			if not clue_tags.has(tag):
				problems.append("fase '%s': il tag '%s' non è fornito da nessuna prova"
						% [phase.get("phase_id", "?"), tag])
	return problems


## Nome storico, usato dai test della v1.
static func _validate_case(data: Dictionary) -> Array[String]:
	return validate_case(data)


static func _validate_picross(puzzle: Dictionary, pid: String, problems: Array[String]) -> void:
	var rows := int(puzzle["grid_size"]["rows"])
	var cols := int(puzzle["grid_size"]["cols"])
	var matrix: Array = puzzle["solution_matrix"]
	if matrix.size() != rows:
		problems.append("puzzle '%s': %d righe invece di %d" % [pid, matrix.size(), rows])
		return
	var filled := 0
	for r in rows:
		var row: Array = matrix[r]
		if row.size() != cols:
			problems.append("puzzle '%s': la riga %d ha %d colonne invece di %d" % [pid, r, row.size(), cols])
			continue
		for c in cols:
			var v := int(row[c])
			if v != 0 and v != 1:
				problems.append("puzzle '%s': valore %s non valido in [%d][%d]" % [pid, str(row[c]), r, c])
			row[c] = v
			filled += v
	if filled == 0:
		problems.append("puzzle '%s': la griglia è vuota" % pid)


## Sigillo Runico: soluzione completa e coerente, givens compatibili con la soluzione.
## L'unicità e la risolvibilità per logica le verifica validate_cases.py (pipeline).
static func _validate_rune_sudoku(puzzle: Dictionary, pid: String, problems: Array[String]) -> void:
	var n := int(puzzle["size"])
	puzzle["size"] = n
	var box: Array = puzzle["box"]
	if box.size() != 2 or int(box[0]) * int(box[1]) != n:
		problems.append("puzzle '%s': i riquadri %s non dividono una griglia %dx%d" % [pid, str(box), n, n])
		return
	puzzle["box"] = [int(box[0]), int(box[1])]
	if (puzzle["runes"] as Array).size() != n:
		problems.append("puzzle '%s': servono %d rune, ce ne sono %d" % [pid, n, (puzzle["runes"] as Array).size()])
	for key in ["solution", "givens"]:
		var m: Array = puzzle[key]
		if m.size() != n:
			problems.append("puzzle '%s': '%s' ha %d righe invece di %d" % [pid, key, m.size(), n])
			return
		for r in n:
			var row: Array = m[r]
			if row.size() != n:
				problems.append("puzzle '%s': '%s' riga %d ha %d colonne" % [pid, key, r, row.size()])
				return
			for c in n:
				row[c] = int(row[c])
	var sol: Array = puzzle["solution"]
	var giv: Array = puzzle["givens"]
	for r in n:
		for c in n:
			var v: int = sol[r][c]
			if v < 0 or v >= n:
				problems.append("puzzle '%s': runa %d fuori intervallo in [%d][%d]" % [pid, v, r, c])
				return
			if giv[r][c] >= 0 and giv[r][c] != v:
				problems.append("puzzle '%s': la runa data in [%d][%d] non coincide con la soluzione" % [pid, r, c])
	# Ogni riga, colonna e riquadro contiene tutte le rune una sola volta
	var br: int = puzzle["box"][0]
	var bc: int = puzzle["box"][1]
	for i in n:
		var row_seen := {}
		var col_seen := {}
		for j in n:
			row_seen[sol[i][j]] = true
			col_seen[sol[j][i]] = true
		if row_seen.size() != n or col_seen.size() != n:
			problems.append("puzzle '%s': la soluzione ripete una runa in riga o colonna %d" % [pid, i])
			return
	for R in range(0, n, br):
		for C in range(0, n, bc):
			var seen := {}
			for r in range(R, R + br):
				for c in range(C, C + bc):
					seen[sol[r][c]] = true
			if seen.size() != n:
				problems.append("puzzle '%s': la soluzione ripete una runa nel riquadro (%d,%d)" % [pid, R, C])
				return


## Cime Aggrovigliate: linee di celle adiacenti, dentro la griglia, senza sovrapposizioni.
static func _validate_arrows(puzzle: Dictionary, pid: String, problems: Array[String]) -> void:
	var rows := int(puzzle["grid_size"]["rows"])
	var cols := int(puzzle["grid_size"]["cols"])
	var used := {}
	var lines: Array = puzzle["lines"]
	if lines.is_empty():
		problems.append("puzzle '%s': nessuna linea" % pid)
		return
	for li in lines.size():
		var cells: Array = lines[li].get("cells", [])
		if cells.size() < 2:
			problems.append("puzzle '%s': la linea %d ha meno di 2 celle" % [pid, li])
			continue
		for k in cells.size():
			var r := int(cells[k][0])
			var c := int(cells[k][1])
			cells[k] = [r, c]
			if r < 0 or c < 0 or r >= rows or c >= cols:
				problems.append("puzzle '%s': la linea %d esce dalla griglia in [%d,%d]" % [pid, li, r, c])
			var key := Vector2i(r, c)
			if used.has(key):
				problems.append("puzzle '%s': la cella [%d,%d] è usata da due linee" % [pid, r, c])
			used[key] = true
			if k > 0:
				var pr: int = cells[k - 1][0]
				var pc: int = cells[k - 1][1]
				if absi(pr - r) + absi(pc - c) != 1:
					problems.append("puzzle '%s': la linea %d non è continua tra [%d,%d] e [%d,%d]" % [pid, li, pr, pc, r, c])
