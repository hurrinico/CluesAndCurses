extends Node

## SaveManager - Autoload globale (Progetto > Impostazioni > Autoload, Nome Nodo: "SaveManager").
## NON dichiarare class_name: in Godot 4 un class_name uguale al nome dell'Autoload
## genera l'errore "Class hides an autoload singleton".
##
## Gestisce:
##   - progressione globale (oro, inchiostro puro, casi, skill, prove raccolte)
##   - scelte morali per i 3 finali (accuse, documenti del Sangue di Pietra, Patti Oscuri)
##   - stato dell'enigma in corso, preso da core.to_dict()
## v1.3 (GDD #07): i metodi sui puzzle accettano qualunque core di enigma
##   (PicrossCore, RuneSudokuCore, ArrowCore): tutti espongono to_dict(), get_stars(),
##   is_damaged e used_corrupted_ink.
## Scrittura atomica (file temporaneo + rinomina): se l'app viene uccisa durante il
## salvataggio, il file precedente resta integro. Nel browser il file vive in IndexedDB.

const SAVE_PATH := "user://cc_save.json"
const TMP_PATH := "user://cc_save.tmp"
const SAVE_VERSION := 1
const SAVE_DELAY := 0.75   # secondi: raggruppa le mosse rapide in un'unica scrittura

## Dopo ogni scrittura riuscita sul disco (AuthService la inoltra al cloud).
signal saved

var game_data: Dictionary = {}

var _dirty: bool = false
var _save_timer: Timer


func _ready() -> void:
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = SAVE_DELAY
	_save_timer.timeout.connect(_flush)
	add_child(_save_timer)
	game_data = _default_data()
	load_game()


func _default_data() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"saved_at": 0.0,                  # ora dell'ultimo salvataggio (secondi Unix): decide locale contro cloud
		"gold": 100,
		"pure_ink": 0,                    # Inchiostro Arcano Puro (aiuti normali)
		"current_case_id": "case_01",
		"unlocked_cases": ["case_01"],
		"unlocked_skills": [],
		# clue_id -> { "integrity": "intact"|"damaged", "stars": int, "corrupted": bool }
		"clues": {},
		# Scelte che decidono i finali (GDD #04, sezione 6).
		# Si salvano i dati GREZZI: se pesi o regole dei finali cambiano, i salvataggi restano validi.
		"moral": {
			# case_id -> { "choice": "dogma"|"revolution"|"darkness", "delta": int }
			"case_choices": {},
			"dark_pacts": 0,              # Patti dell'Inchiostro Corrotto accettati
		},
		# { "case_id", "puzzle_id", "state": core.to_dict() }
		"active_puzzle": {},
		# case_id -> { "step": int (passo della storia in CaseScene), "tags": [tag ottenuti da testimonianze] }
		"case_progress": {},
		"completed_cases": [],            # casi conclusi almeno una volta (sbloccano i successivi)
	}


# =====================================================================
# 1. SALVATAGGIO / CARICAMENTO
# =====================================================================
## Salvataggio differito: da usare a ogni mossa del puzzle.
func request_save() -> void:
	_dirty = true
	if _save_timer.is_stopped():
		_save_timer.start()


## Salvataggio immediato: fine puzzle, cambio scena, app in pausa.
func save_game(keep_time: bool = false) -> bool:
	_save_timer.stop()
	_dirty = false
	if not keep_time:
		game_data["saved_at"] = Time.get_unix_time_from_system()
	var file := FileAccess.open(TMP_PATH, FileAccess.WRITE)
	if file == null:
		printerr("[SaveManager] Impossibile scrivere il salvataggio: ", FileAccess.get_open_error())
		return false
	file.store_string(JSON.stringify(game_data))
	file.close()
	var err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(TMP_PATH),
		ProjectSettings.globalize_path(SAVE_PATH))
	if err != OK:
		printerr("[SaveManager] Rinomina del salvataggio fallita: ", error_string(err))
		return false
	saved.emit()
	return true


## Sostituisce i progressi con quelli arrivati dal cloud (AuthService) e li scrive sul disco.
## L'ora del salvataggio resta quella del cloud, così i due lati risultano allineati.
func replace_data(data: Dictionary) -> void:
	game_data = _default_data()
	_merge(game_data, data)
	_fix_number_types()
	game_data["version"] = SAVE_VERSION
	save_game(true)


func load_game() -> void:
	var loaded := _read_json(SAVE_PATH)
	if loaded.is_empty():
		# Il principale manca o è rotto: proviamo il temporaneo (app chiusa a metà scrittura)
		loaded = _read_json(TMP_PATH)
	if loaded.is_empty():
		print("[SaveManager] Nessun salvataggio valido: nuovo profilo.")
		return
	_merge(game_data, loaded)
	_fix_number_types()
	game_data["version"] = SAVE_VERSION


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		printerr("[SaveManager] File non valido: ", path)
		return {}
	return parsed


## Fusione ricorsiva: le chiavi aggiunte in versioni future del gioco
## restano ai valori predefiniti anche dentro i dizionari annidati.
func _merge(target: Dictionary, source: Dictionary) -> void:
	for key in source:
		if target.has(key) and target[key] is Dictionary and source[key] is Dictionary \
				and not (target[key] as Dictionary).is_empty():
			_merge(target[key], source[key])
		else:
			target[key] = source[key]


## JSON restituisce tutti i numeri come float: riportiamo a int i contatori.
func _fix_number_types() -> void:
	game_data["saved_at"] = float(game_data.get("saved_at", 0.0))
	game_data["gold"] = int(game_data["gold"])
	game_data["pure_ink"] = int(game_data["pure_ink"])
	game_data["moral"]["dark_pacts"] = int(game_data["moral"]["dark_pacts"])
	for case_id in game_data["moral"]["case_choices"]:
		var choice: Dictionary = game_data["moral"]["case_choices"][case_id]
		choice["delta"] = int(choice.get("delta", 0))
	for clue_id in game_data["clues"]:
		var clue: Dictionary = game_data["clues"][clue_id]
		clue["stars"] = int(clue.get("stars", 0))


func _flush() -> void:
	if _dirty:
		save_game()


# =====================================================================
# 2. ENIGMA IN CORSO (sessioni mobile "mordi e fuggi")
# =====================================================================
## Collegare ai segnali di modifica del core (o chiamare dopo ogni gesto).
## core: PicrossCore, RuneSudokuCore o ArrowCore (serve solo to_dict()).
func save_puzzle_state(case_id: String, puzzle_id: String, core: Node) -> void:
	game_data["active_puzzle"] = {
		"case_id": case_id,
		"puzzle_id": puzzle_id,
		"state": core.to_dict(),
	}
	request_save()


func has_active_puzzle() -> bool:
	return game_data["active_puzzle"].get("puzzle_id", "") != ""


## Stato salvato dell'enigma, se è proprio quello indicato ({} altrimenti).
func get_saved_state_for(case_id: String, puzzle_id: String) -> Dictionary:
	var active: Dictionary = game_data["active_puzzle"]
	if active.get("case_id", "") == case_id and active.get("puzzle_id", "") == puzzle_id:
		return active.get("state", {})
	return {}


## Da passare a core.load_state() DOPO core.setup_puzzle().
func get_active_puzzle_state() -> Dictionary:
	return game_data["active_puzzle"].get("state", {})


func clear_puzzle_state() -> void:
	game_data["active_puzzle"] = {}
	save_game()


# =====================================================================
# 3. PROVE E SCELTE MORALI
# =====================================================================
## Da chiamare quando l'enigma è risolto: registra la prova con integrità e stelle.
## Conserva il risultato migliore se l'enigma viene rigiocato.
func record_clue(clue_id: String, core: Node) -> void:
	var new_entry := {
		"integrity": "damaged" if core.is_damaged else "intact",
		"stars": core.get_stars(),
		"corrupted": core.used_corrupted_ink,
	}
	var old: Dictionary = game_data["clues"].get(clue_id, {})
	if old.is_empty() or new_entry["stars"] > int(old.get("stars", 0)):
		game_data["clues"][clue_id] = new_entry
	clear_puzzle_state()   # include save_game()


func has_clue(clue_id: String) -> bool:
	return game_data["clues"].has(clue_id)


func is_clue_damaged(clue_id: String) -> bool:
	return game_data["clues"].get(clue_id, {}).get("integrity", "") == "damaged"


## Chiamare SOLO dopo [Accetta il Patto] nel pop-up Patto Oscuro.
func register_dark_pact() -> void:
	game_data["moral"]["dark_pacts"] += 1
	save_game()


## Scelta di fine caso (casi 2-4). choice: "dogma" | "revolution" | "darkness".
## delta arriva dal JSON del caso, così i pesi si bilanciano senza toccare il codice.
func record_case_choice(case_id: String, choice: String, delta: int) -> void:
	game_data["moral"]["case_choices"][case_id] = { "choice": choice, "delta": delta }
	save_game()


# =====================================================================
# 3b. AVANZAMENTO DELLA STORIA DEL CASO (CaseScene)
# =====================================================================
func get_case_step(case_id: String) -> int:
	return int(game_data["case_progress"].get(case_id, {}).get("step", 0))


func set_case_step(case_id: String, step: int) -> void:
	var entry: Dictionary = game_data["case_progress"].get(case_id, {"step": 0, "tags": []})
	entry["step"] = step
	game_data["case_progress"][case_id] = entry
	save_game()


func get_case_tags(case_id: String) -> Array:
	return game_data["case_progress"].get(case_id, {}).get("tags", [])


func add_case_tag(case_id: String, tag: String) -> void:
	var entry: Dictionary = game_data["case_progress"].get(case_id, {"step": 0, "tags": []})
	if not entry.has("tags"):
		entry["tags"] = []
	if not (tag in entry["tags"]):
		entry["tags"].append(tag)
	game_data["case_progress"][case_id] = entry
	save_game()


func mark_case_completed(case_id: String) -> void:
	var entry: Dictionary = game_data["case_progress"].get(case_id, {"step": 0, "tags": []})
	entry["completed"] = true
	game_data["case_progress"][case_id] = entry
	save_game()


## Concluso almeno una volta (resta vero anche se poi il caso viene rigiocato).
func is_case_completed(case_id: String) -> bool:
	return bool(game_data["case_progress"].get(case_id, {}).get("completed", false)) \
			or case_id in game_data.get("completed_cases", [])


## Rigioca il caso da capo: cancella avanzamento, prove raccolte, scelta finale e puzzle in corso.
## I Patti Oscuri accettati restano: sono scelte morali già fatte.
func reset_case(case_id: String, clue_ids: Array) -> void:
	if is_case_completed(case_id) and not (case_id in game_data["completed_cases"]):
		game_data["completed_cases"].append(case_id)   # lo sblocco dei casi successivi resta
	game_data["case_progress"].erase(case_id)
	game_data["moral"]["case_choices"].erase(case_id)
	for clue_id in clue_ids:
		game_data["clues"].erase(clue_id)
	game_data["active_puzzle"] = {}
	save_game()


# =====================================================================
# 4. CALCOLO DEL FINALE (soglie del GDD #04, sezione 6)
# =====================================================================
const DARK_PACT_PENALTY := -1
const DARK_THRESHOLD := -4      # punteggio <= -4  -> Finale Oscuro
const JUSTICE_THRESHOLD := 4    # punteggio >= +4  -> Finale della Giustizia


func get_morality_score() -> int:
	var score := 0
	for case_id in game_data["moral"]["case_choices"]:
		score += int(game_data["moral"]["case_choices"][case_id]["delta"])
	score += int(game_data["moral"]["dark_pacts"]) * DARK_PACT_PENALTY
	return clampi(score, -10, 10)


## Restituisce "darkness", "revolution" o "justice".
func compute_ending() -> String:
	var score := get_morality_score()
	if score <= DARK_THRESHOLD:
		return "darkness"
	if score >= JUSTICE_THRESHOLD:
		return "justice"
	return "revolution"


# =====================================================================
# 5. CICLO DI VITA MOBILE (e scheda del browser nascosta o chiusa)
# =====================================================================
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT, \
		NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_WM_GO_BACK_REQUEST:
			if _dirty:
				save_game()
