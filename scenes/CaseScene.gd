extends Control

## Un caso dall'inizio alla fine: dialoghi con ritratti, le prove (Picross, Sigillo Runico,
## Cime Aggrovigliate), gli interrogatori (contraddizione, testimonianza, accusa) ed epilogo.
## Tutti i testi, i ritratti e gli sfondi vengono dal JSON del caso (chiavi "characters",
## "backgrounds", "story" e campi *_mood delle fasi): si modifica la storia senza toccare il codice.
##
## La storia è una lista di passi (_build_steps). Il passo corrente viene salvato in
## SaveManager, quindi chiudendo il gioco si riprende dallo stesso punto.
##
## Gerarchia costruita in _build():
## CaseScene (Control, questo script)
## ├── Background (TextureRect, sfondo 360x640 "cover")
## ├── Portrait (TextureRect, ritratto 160x200 mostrato a 2x)
## ├── ItemFlash (TextureRect, l'oggetto presentato in interrogatorio)
## ├── Choices (VBoxContainer, pulsanti di scelta sopra il riquadro)
## ├── DialogBox (PanelContainer 9-slice U4)
## │   └── VBox: Text (Label con effetto macchina da scrivere) + NextMark
## ├── NamePlate (PanelContainer con il nome di chi parla)
## ├── FileButton ("Fascicolo", in alto a destra)
## ├── [scena dell'enigma in modalità caso, aggiunta al bisogno]
## ├── [Overlay: fascicolo, scelta della prova, riepilogo]
## └── Fade (ColorRect per le transizioni)

signal _advance_requested
signal _choice_made(index: int)

## Scena da usare per ogni tipo di enigma (GDD #07). Tutte espongono la stessa interfaccia:
## case_path, forced_index, background_texture e il segnale finished.
const PUZZLE_SCENES := {
	"picross": "res://scenes/PuzzleTest.tscn",
	"rune_sudoku": "res://scenes/RuneSudokuScene.tscn",
	"arrows": "res://scenes/ArrowScene.tscn",
}
const MAP_SCENE := "res://scenes/CaseSelect.tscn"
const PANEL_TEX := "res://assets/ui/U4_pannello_dialogo.png"
const STAR_FULL := "res://assets/tiles/icon_star_full.png"
const STAR_EMPTY := "res://assets/tiles/icon_star_empty.png"
const FONT_BOLD := "res://assets/fonts/PixelifySans-SemiBold.ttf"

const TYPE_SPEED := 0.022        # secondi per carattere
const PORTRAIT_SCALE := 2        # 160x200 -> 320x400, pixel interi

# --- Palette Clues & Curses (GDD #05) ---
const C_NIGHT_0 := Color("0b0a12")
const C_NIGHT_1 := Color("14121f")
const C_NIGHT_6 := Color("56607e")
const C_NIGHT_7 := Color("7a83a0")
const C_WOOD_1 := Color("33201a")
const C_WOOD_2 := Color("4a2e21")
const C_WOOD_3 := Color("66412b")
const C_WOOD_4 := Color("85593a")
const C_FLAME_1 := Color("dba04a")
const C_FLAME_2 := Color("f0c060")
const C_TEXT := Color("fff4cc")
const C_BLOOD := Color("cc3a2e")
const C_ARCANE_2 := Color("a050b0")

## Caso da giocare. Vuoto = SaveManager.game_data["current_case_id"] (scelto al Tavolo delle Mappe).
@export var case_path: String = ""

var case_data: Dictionary = {}
var case_id: String = ""
var steps: Array = []
var step_index: int = 0

var _bg: TextureRect
var _bg_key: String = ""
var _portrait: TextureRect
var _portrait_key: String = ""
var _item_flash: TextureRect
var _choices: VBoxContainer
var _box: PanelContainer
var _text: Label
var _next_mark: Control
var _name_plate: PanelContainer
var _name_label: Label
var _file_button: Button
var _overlay: Control
var _fade: ColorRect
var _puzzle: Control

var _typing: Tween
var _waiting_tap: bool = false


# =====================================================================
# 1. AVVIO
# =====================================================================
func _ready() -> void:
	theme = _make_theme()
	_build()
	if case_path == "":
		case_path = "res://data/cases/%s.json" % SaveManager.game_data.get("current_case_id", "case_01")
	case_data = CaseLoader.load_case(case_path)
	if case_data.is_empty():
		_box.visible = true
		_text.text = "Errore nel caricamento del caso."
		return
	case_id = case_data["case_id"]
	_build_steps()
	step_index = clampi(SaveManager.get_case_step(case_id), 0, steps.size())
	_run()


func _build_steps() -> void:
	steps = build_steps(case_data)


## Trasforma i dati del caso in una lista lineare di passi.
## Statica: la usa anche il Tavolo delle Mappe per sapere se un caso è concluso.
static func build_steps(data: Dictionary) -> Array:
	var story: Dictionary = data.get("story", {})
	var out: Array = []
	_add_lines_step(out, story.get("intro", []))
	var puzzles: Array = data["puzzles"]
	for i in puzzles.size():
		var pid: String = puzzles[i]["puzzle_id"]
		_add_lines_step(out, story.get("before_puzzle", {}).get(pid, []))
		out.append({"type": "puzzle", "index": i})
		_add_lines_step(out, story.get("after_puzzle", {}).get(pid, []))
	_add_lines_step(out, story.get("before_interrogations", []))
	for phase in data["interrogation_phases"]:
		out.append({"type": "phase", "phase": phase})
		if phase["type"] == "accusation":
			_add_lines_step(out, story.get("after_accusation", []))
		_add_lines_step(out, story.get("after_phase", {}).get(phase["phase_id"], []))
	if data.has("final_choice"):
		out.append({"type": "choice", "choice": data["final_choice"]})
	_add_lines_step(out, story.get("epilogue", []))
	return out


static func _add_lines_step(out: Array, lines: Array) -> void:
	if not lines.is_empty():
		out.append({"type": "lines", "lines": lines})


func _run() -> void:
	# Sfondo del punto di ripresa: l'ultimo "bg" indicato nei passi precedenti
	var bg_key: String = case_data.get("start_background", "stanza")
	for i in step_index:
		var lines: Array = []
		if steps[i]["type"] == "lines":
			lines = steps[i]["lines"]
		elif steps[i]["type"] == "choice":
			lines = steps[i]["choice"].get("intro", [])
		for line in lines:
			bg_key = line.get("bg", bg_key)
	_set_background_now(bg_key)
	var t := create_tween()
	t.tween_property(_fade, "color:a", 0.0, 0.8)
	await t.finished

	while step_index < steps.size():
		SaveManager.set_case_step(case_id, step_index)
		await _run_step(steps[step_index])
		step_index += 1
	SaveManager.set_case_step(case_id, step_index)
	SaveManager.mark_case_completed(case_id)
	_show_summary()


func _run_step(step: Dictionary) -> void:
	match step["type"]:
		"lines":
			for line in step["lines"]:
				await say(line)
		"puzzle":
			await _run_puzzle(step["index"])
		"choice":
			await _run_choice(step["choice"])
		"phase":
			var phase: Dictionary = step["phase"]
			match phase["type"]:
				"contradiction":
					await _run_contradiction(phase)
				"testimony":
					await _run_testimony(phase)
				"accusation":
					await _run_accusation(phase)


# =====================================================================
# 2. DIALOGHI
# =====================================================================
## Mostra una battuta e attende il tocco del giocatore.
func say(line: Dictionary) -> void:
	await show_line(line)
	_waiting_tap = true
	await _advance_requested
	_waiting_tap = false


## Mostra una battuta senza attendere (usata prima delle scelte).
## Campi: who ("narrator" o id personaggio), mood, text, name (facoltativo), bg (facoltativo).
func show_line(line: Dictionary) -> void:
	if line.has("bg") and line["bg"] != _bg_key:
		await _change_background(line["bg"])
	var who: String = line.get("who", "narrator")
	var chars: Dictionary = case_data.get("characters", {})
	if who == "narrator" or not chars.has(who):
		_set_portrait("", "")
		_name_plate.visible = false
	else:
		_set_portrait(who, line.get("mood", "neutral"))
		_name_label.text = line.get("name", chars[who]["name"])
		_name_plate.visible = true
	_box.visible = true
	_text.text = line.get("text", "")
	_text.add_theme_color_override("font_color", C_NIGHT_7.lightened(0.35) if who == "narrator" else C_TEXT)
	_text.visible_characters = 0
	_next_mark.visible = false
	if _typing:
		_typing.kill()
	var n := _text.get_total_character_count()
	_typing = create_tween()
	_typing.tween_property(_text, "visible_characters", n, n * TYPE_SPEED)
	_typing.finished.connect(_finish_typing)


func _finish_typing() -> void:
	if _typing:
		_typing.kill()
		_typing = null
	_text.visible_characters = -1
	_next_mark.visible = _waiting_tap


func _on_tap() -> void:
	if _typing and _typing.is_running():
		_finish_typing()
		_next_mark.visible = _waiting_tap
	elif _waiting_tap:
		_advance_requested.emit()


func _gui_input(event: InputEvent) -> void:
	# Solo il mouse: su telefono il tocco viene convertito anche in clic,
	# accettare entrambi farebbe saltare due battute con un solo tocco.
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		_on_tap()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_pressed() and not event.is_echo() and _overlay == null and _puzzle == null:
		if event is InputEventKey and (event.keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]):
			_on_tap()


func _set_portrait(who: String, mood: String) -> void:
	var key := who + "/" + mood
	if key == _portrait_key:
		return
	_portrait_key = key
	if who == "":
		create_tween().tween_property(_portrait, "modulate:a", 0.0, 0.15)
		return
	var portraits: Dictionary = case_data["characters"][who]["portraits"]
	var path: String = portraits.get(mood, portraits.get("neutral", ""))
	if path == "" or not ResourceLoader.exists(path):
		_portrait.modulate.a = 0.0
		return
	var same_character: bool = _portrait.modulate.a > 0.5 and _portrait.get_meta("who", "") == who
	_portrait.texture = load(path)
	_portrait.set_meta("who", who)
	if same_character:
		return   # stesso personaggio: cambia solo l'espressione, senza animazione
	_portrait.modulate.a = 0.0
	create_tween().tween_property(_portrait, "modulate:a", 1.0, 0.2)


func _set_background_now(key: String) -> void:
	var path: String = case_data.get("backgrounds", {}).get(key, "")
	_bg_key = key
	if path != "" and ResourceLoader.exists(path):
		_bg.texture = load(path)


func _change_background(key: String) -> void:
	_set_portrait("", "")
	var t := create_tween()
	t.tween_property(_fade, "color:a", 1.0, 0.35)
	await t.finished
	_set_background_now(key)
	t = create_tween()
	t.tween_property(_fade, "color:a", 0.0, 0.45)
	await t.finished


## Pulsanti di scelta sopra il riquadro dei dialoghi. Restituisce l'indice scelto.
func choose(options: Array) -> int:
	_clear_choices()
	while _typing and _typing.is_running():   # prima si legge tutta la dichiarazione
		await get_tree().process_frame
	for i in options.size():
		var b := _make_button(options[i])
		b.custom_minimum_size.y = 44
		b.pressed.connect(func(): _choice_made.emit(i))
		_choices.add_child(b)
	var picked: int = await _choice_made
	_clear_choices()
	return picked


func _clear_choices() -> void:
	for child in _choices.get_children():
		child.queue_free()


## L'oggetto presentato appare al centro, poi svanisce.
func _flash_item(sprite_path: String) -> void:
	if sprite_path == "" or not ResourceLoader.exists(sprite_path):
		return
	_item_flash.texture = load(sprite_path)
	_item_flash.scale = Vector2(0.6, 0.6)
	var t := create_tween()
	t.set_parallel()
	t.tween_property(_item_flash, "modulate:a", 1.0, 0.2)
	t.tween_property(_item_flash, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.chain().tween_interval(0.7)
	t.chain().tween_property(_item_flash, "modulate:a", 0.0, 0.3)
	await t.finished


# =====================================================================
# 3. PROVE (scena scelta in base al tipo di enigma)
# =====================================================================
func _run_puzzle(index: int) -> void:
	var puzzle: Dictionary = case_data["puzzles"][index]
	var clue: Dictionary = puzzle["reward_clue"]
	if SaveManager.has_clue(clue["clue_id"]):
		return   # già risolta (ripresa dopo la vittoria)
	_box.visible = false
	_name_plate.visible = false
	_file_button.visible = false
	_set_portrait("", "")

	var scene_path: String = PUZZLE_SCENES.get(CaseLoader.puzzle_type(puzzle), PUZZLE_SCENES["picross"])
	_puzzle = load(scene_path).instantiate()
	_puzzle.case_path = case_path
	_puzzle.forced_index = index
	_puzzle.background_texture = _bg.texture
	add_child(_puzzle)
	move_child(_puzzle, _fade.get_index())
	await _puzzle.finished

	var t := create_tween()
	t.tween_property(_fade, "color:a", 1.0, 0.3)
	await t.finished
	_puzzle.queue_free()
	_puzzle = null
	_file_button.visible = true
	t = create_tween()
	t.tween_property(_fade, "color:a", 0.0, 0.4)
	await t.finished


# =====================================================================
# 4. INTERROGATORI
# =====================================================================
func _run_contradiction(phase: Dictionary) -> void:
	var who: String = phase["suspect_id"]
	while true:
		await show_line({"who": who, "mood": phase.get("statement_mood", "neutral"), "text": phase["statement"]})
		await choose(["Presenta una prova"])
		var clue := await _pick_evidence("Quale prova smentisce la dichiarazione?")
		if clue.is_empty():
			continue
		await say({"who": "alaric", "mood": "accuse", "text": "Allora spiegatemi questo: %s." % clue["name"]})
		await _flash_item(clue.get("sprite_path", ""))
		if phase["target_tag"] in clue.get("tags", []):
			var damaged := SaveManager.is_clue_damaged(clue["clue_id"])
			var text: String = phase["damaged_dialogue"] if damaged else phase["success_dialogue"]
			await say({"who": who, "mood": phase.get("success_mood", "neutral"), "text": text})
			return
		await say({"who": who, "mood": phase.get("failure_mood", "neutral"), "text": phase["failure_dialogue"]})
		await say({"who": "narrator", "text": "Questa prova non contraddice le sue parole. Rileggi la dichiarazione e scegli di nuovo."})


func _run_testimony(phase: Dictionary) -> void:
	var who: String = phase["suspect_id"]
	await show_line({"who": who, "mood": phase.get("statement_mood", "neutral"), "text": phase["statement"]})
	await choose([phase["question"]])
	await say({"who": "alaric", "mood": "focused", "text": phase["question"]})
	await say({"who": who, "mood": phase.get("success_mood", "neutral"), "text": phase["testimony_dialogue"]})
	if phase.has("grants_tag"):
		SaveManager.add_case_tag(case_id, phase["grants_tag"])
		await say({"who": "narrator", "text": "Testimonianza aggiunta al fascicolo."})


func _run_accusation(phase: Dictionary) -> void:
	var suspects: Array = case_data["suspects"]
	while true:
		await show_line({"who": "alaric", "mood": "focused", "text": phase["prompt"]})
		var picked := await _choose_suspect(suspects)
		var sid: String = suspects[picked]["suspect_id"]
		if sid == phase["culprit_id"] and _has_tags(phase.get("required_tags", [])):
			await say({"who": "alaric", "mood": phase.get("accuser_mood", "accuse"), "text": phase["success_dialogue"]})
			return
		await say({"who": sid, "mood": _defensive_mood(sid), "text": phase["wrong_accusation_dialogue"]})
		if not phase.get("allow_retry", true):
			return


func _has_tags(tags: Array) -> bool:
	var owned := _owned_tags()
	for tag in tags:
		if not (tag in owned):
			return false
	return true


func _owned_tags() -> Array:
	var owned: Array = SaveManager.get_case_tags(case_id).duplicate()
	for clue in _collected_clues():
		owned.append_array(clue.get("tags", []))
	return owned


func _defensive_mood(who: String) -> String:
	var portraits: Dictionary = case_data["characters"].get(who, {}).get("portraits", {})
	for mood in ["scornful", "nervous", "scared"]:
		if portraits.has(mood):
			return mood
	return "neutral"


## Tre volti cliccabili (ritaglio del ritratto sulla testa).
func _choose_suspect(suspects: Array) -> int:
	_clear_choices()
	while _typing and _typing.is_running():
		await get_tree().process_frame
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 4)
	_choices.add_child(row)
	for i in suspects.size():
		var sid: String = suspects[i]["suspect_id"]
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(96, 124)
		b.pressed.connect(func(): _choice_made.emit(i))
		row.add_child(b)
		var col := VBoxContainer.new()
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.alignment = BoxContainer.ALIGNMENT_CENTER
		col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		b.add_child(col)
		var face := TextureRect.new()
		face.mouse_filter = Control.MOUSE_FILTER_IGNORE
		face.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		var portraits: Dictionary = case_data["characters"][sid]["portraits"]
		var atlas := AtlasTexture.new()
		atlas.atlas = load(portraits.get("neutral", portraits.values()[0]))
		atlas.region = Rect2(36, 4, 88, 88)
		face.texture = atlas
		col.add_child(face)
		var lbl := Label.new()
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl.text = String(case_data["characters"][sid]["name"]).get_slice(" il ", 0)   # "Garrett", "Lady Lyra", "Kaelen"
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 12)
		col.add_child(lbl)
	var picked: int = await _choice_made
	_clear_choices()
	return picked


# =====================================================================
# 5. FASCICOLO
# =====================================================================
func _collected_clues() -> Array:
	var out: Array = []
	for puzzle in case_data.get("puzzles", []):
		var clue: Dictionary = puzzle["reward_clue"]
		if SaveManager.has_clue(clue["clue_id"]):
			out.append(clue)
	return out


## Elenco delle prove: se selectable, restituisce la prova scelta ({} = indietro).
func _pick_evidence(title: String) -> Dictionary:
	var clues := _collected_clues()
	var box := _open_overlay()
	_add_label(box, "FASCICOLO", 12, C_FLAME_1)
	_add_label(box, title, 12, C_TEXT)
	for i in clues.size():
		box.add_child(_evidence_row(clues[i], func(): _choice_made.emit(i), false))
	var back := _make_button("Indietro")
	back.pressed.connect(func(): _choice_made.emit(-1))
	box.add_child(back)
	var picked: int = await _choice_made
	_close_overlay()
	return {} if picked < 0 else clues[picked]


func _on_file_pressed() -> void:
	if _overlay:
		return
	var box := _open_overlay()
	_add_label(box, "FASCICOLO", 12, C_FLAME_1)
	_add_label(box, case_data.get("title", ""), 12, C_TEXT)
	var clues := _collected_clues()
	if clues.is_empty():
		_add_label(box, "Nessuna prova raccolta finora.", 12, C_NIGHT_7)
	for clue in clues:
		box.add_child(_evidence_row(clue, Callable(), true))
	var tags := SaveManager.get_case_tags(case_id)
	for phase in case_data["interrogation_phases"]:
		if phase["type"] == "testimony" and phase.get("grants_tag", "") in tags:
			var who: String = case_data["characters"].get(phase["suspect_id"], {}).get("name", phase["suspect_id"])
			var summary: String = phase.get("testimony_summary", phase["testimony_dialogue"])
			_add_label(box, "Testimonianza (%s): %s" % [who, summary], 11, C_NIGHT_7)
	var close := _make_button("Chiudi")
	close.pressed.connect(_close_overlay)
	box.add_child(close)


func _evidence_row(clue: Dictionary, on_pick: Callable, show_description: bool) -> Control:
	# Il PanelContainer dà la misura giusta a tutti i figli: sotto c'è il pulsante
	# (o un semplice fondo), sopra la riga con illustrazione e testi.
	var holder := PanelContainer.new()
	var empty := StyleBoxEmpty.new()
	holder.add_theme_stylebox_override("panel", empty)
	if on_pick.is_valid():
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(on_pick)
		holder.add_child(b)
	else:
		var back := Panel.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = C_WOOD_1
		back.add_theme_stylebox_override("panel", sb)
		back.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(back)
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 4)
	holder.add_child(margin)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)
	margin.add_child(row)
	var pic := TextureRect.new()
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	pic.custom_minimum_size = Vector2(64, 64)
	var path: String = clue.get("sprite_path", "")
	if path != "" and ResourceLoader.exists(path):
		pic.texture = load(path)
	row.add_child(pic)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(col)
	var name_lbl := _add_label(col, clue["name"], 12, C_TEXT)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	var state := "Danneggiata" if SaveManager.is_clue_damaged(clue["clue_id"]) else "Integra"
	var state_lbl := _add_label(col, state, 10, C_BLOOD if state == "Danneggiata" else C_NIGHT_7)
	state_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	if show_description:
		var d := _add_label(col, clue.get("description", ""), 10, C_NIGHT_7)
		d.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	for lbl in col.get_children():
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return holder


# =====================================================================
# 6. FINE DEL CASO
# =====================================================================
func _show_summary() -> void:
	_box.visible = false
	_name_plate.visible = false
	_set_portrait("", "")
	var box := _open_overlay()
	_add_label(box, "CASO CHIUSO", 12, C_FLAME_1)
	_add_label(box, case_data.get("title", ""), 16, C_TEXT)
	for phase in case_data["interrogation_phases"]:
		if phase["type"] == "accusation":
			var culprit: String = phase["culprit_id"]
			_add_label(box, "Colpevole: " + case_data["characters"].get(culprit, {}).get("name", culprit), 12, C_FLAME_2)
	var total := 0
	var max_total := 0
	for puzzle in case_data["puzzles"]:
		var clue: Dictionary = puzzle["reward_clue"]
		var info: Dictionary = SaveManager.game_data["clues"].get(clue["clue_id"], {})
		var stars := int(info.get("stars", 0))
		total += stars
		max_total += 3
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		box.add_child(row)
		var lbl := _add_label(row, clue["name"], 11, C_TEXT)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for s in 3:
			var star := TextureRect.new()
			star.texture = load(STAR_FULL if s < stars else STAR_EMPTY)
			star.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
			row.add_child(star)
	_add_label(box, "Stelle: %d su %d" % [total, max_total], 12, C_FLAME_2)
	var choice_entry: Dictionary = SaveManager.game_data["moral"]["case_choices"].get(case_id, {})
	if not choice_entry.is_empty() and case_data.has("final_choice"):
		for opt in case_data["final_choice"]["options"]:
			if opt["choice"] == choice_entry.get("choice", ""):
				_add_label(box, "Scelta: " + opt["label"], 11, C_ARCANE_2 if opt["choice"] == "darkness" else C_FLAME_2)
	var pacts := int(SaveManager.game_data["moral"]["dark_pacts"])
	if pacts > 0:
		_add_label(box, "Patti Oscuri accettati: %d" % pacts, 11, C_ARCANE_2)
	_add_label(box, "Grazie per aver giocato il prototipo di Clues & Curses.", 11, C_NIGHT_7)
	var again := _make_button("Rigioca il caso")
	again.pressed.connect(_replay_case)
	box.add_child(again)
	var map := _make_button("Tavolo delle Mappe")
	map.pressed.connect(func(): get_tree().change_scene_to_file(MAP_SCENE))
	box.add_child(map)


# =====================================================================
# 5b. SCELTA DI FINE CASO (GDD #04, 6.1: Dogma / Rivoluzione / Tenebra)
# =====================================================================
func _run_choice(choice: Dictionary) -> void:
	var recorded: Dictionary = SaveManager.game_data["moral"]["case_choices"].get(case_id, {})
	var options: Array = choice["options"]
	var picked := -1
	for i in options.size():
		if options[i]["choice"] == recorded.get("choice", ""):
			picked = i   # ripresa dopo la scelta: si rivede solo l'esito
	if picked < 0:
		for line in choice.get("intro", []):
			await say(line)
		await show_line({"who": "alaric", "mood": "focused", "text": choice.get("prompt", "")})
		picked = await _choose_option(options)
		var opt: Dictionary = options[picked]
		SaveManager.record_case_choice(case_id, opt["choice"], int(opt.get("delta", 0)))
	for line in options[picked].get("result", []):
		await say(line)


## Le tre strade come pulsanti con titolo e descrizione.
func _choose_option(options: Array) -> int:
	_clear_choices()
	while _typing and _typing.is_running():
		await get_tree().process_frame
	for i in options.size():
		var opt: Dictionary = options[i]
		var holder := PanelContainer.new()
		holder.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func(): _choice_made.emit(i))
		holder.add_child(b)
		var margin := MarginContainer.new()
		margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for side in ["left", "right", "top", "bottom"]:
			margin.add_theme_constant_override("margin_" + side, 6)
		holder.add_child(margin)
		var col := VBoxContainer.new()
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_theme_constant_override("separation", 2)
		margin.add_child(col)
		var color := C_ARCANE_2 if opt["choice"] == "darkness" else C_FLAME_2
		var title := _add_label(col, opt["label"], 12, color)
		var desc := _add_label(col, opt.get("description", ""), 10, C_TEXT)
		for lbl in [title, desc]:
			lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_choices.add_child(holder)
	var picked: int = await _choice_made
	_clear_choices()
	return picked


func _replay_case() -> void:
	var ids: Array = []
	for puzzle in case_data["puzzles"]:
		ids.append(puzzle["reward_clue"]["clue_id"])
	SaveManager.reset_case(case_id, ids)
	get_tree().reload_current_scene()


# =====================================================================
# 7. COSTRUZIONE DELLA UI
# =====================================================================
func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var base := ColorRect.new()
	base.color = C_NIGHT_0
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(base)
	base.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_bg = TextureRect.new()
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_portrait = TextureRect.new()
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_SCALE
	_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_portrait.modulate.a = 0.0
	add_child(_portrait)
	var pw := 160 * PORTRAIT_SCALE
	var ph := 200 * PORTRAIT_SCALE
	_portrait.anchor_left = 0.5
	_portrait.anchor_right = 0.5
	_portrait.anchor_top = 1.0
	_portrait.anchor_bottom = 1.0
	_portrait.offset_left = -pw / 2.0
	_portrait.offset_right = pw / 2.0
	_portrait.offset_bottom = -110     # la parte bassa resta dietro il riquadro
	_portrait.offset_top = -110 - ph

	_item_flash = TextureRect.new()
	_item_flash.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_item_flash.stretch_mode = TextureRect.STRETCH_SCALE
	_item_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_item_flash.modulate.a = 0.0
	add_child(_item_flash)
	_item_flash.anchor_left = 0.5
	_item_flash.anchor_right = 0.5
	_item_flash.offset_left = -64
	_item_flash.offset_right = 64
	_item_flash.offset_top = 150
	_item_flash.offset_bottom = 278
	_item_flash.pivot_offset = Vector2(64, 64)

	_box = PanelContainer.new()
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxTexture.new()
	sb.texture = load(PANEL_TEX)
	sb.set_texture_margin_all(16)
	sb.set_content_margin_all(14)
	sb.content_margin_top = 18
	_box.add_theme_stylebox_override("panel", sb)
	_box.visible = false
	add_child(_box)
	_box.anchor_left = 0.0
	_box.anchor_right = 1.0
	_box.anchor_top = 1.0
	_box.anchor_bottom = 1.0
	_box.offset_left = 8
	_box.offset_right = -8
	_box.offset_top = -170
	_box.offset_bottom = -10

	var inner := VBoxContainer.new()
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.add_child(inner)
	_text = Label.new()
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text.add_theme_font_size_override("font_size", 13)
	_text.add_theme_constant_override("line_spacing", 3)
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(_text)
	_next_mark = Control.new()
	_next_mark.custom_minimum_size = Vector2(0, 6)
	_next_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_next_mark.draw.connect(func():
		var x := _next_mark.size.x - 10
		_next_mark.draw_colored_polygon(PackedVector2Array([Vector2(x, 0), Vector2(x + 8, 0), Vector2(x + 4, 5)]), C_FLAME_2))
	inner.add_child(_next_mark)
	var blink := create_tween().set_loops()
	blink.tween_property(_next_mark, "modulate:a", 0.3, 0.5)
	blink.tween_property(_next_mark, "modulate:a", 1.0, 0.5)

	_name_plate = PanelContainer.new()
	_name_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var nsb := StyleBoxFlat.new()
	nsb.bg_color = C_WOOD_1
	nsb.border_color = C_FLAME_1
	nsb.set_border_width_all(1)
	nsb.content_margin_left = 8
	nsb.content_margin_right = 8
	nsb.content_margin_top = 3
	nsb.content_margin_bottom = 3
	_name_plate.add_theme_stylebox_override("panel", nsb)
	_name_plate.visible = false
	add_child(_name_plate)
	_name_plate.anchor_top = 1.0
	_name_plate.anchor_bottom = 1.0
	_name_plate.offset_left = 20
	_name_plate.offset_top = -186
	_name_plate.offset_bottom = -164
	_name_label = Label.new()
	_name_label.add_theme_font_override("font", load(FONT_BOLD))
	_name_label.add_theme_font_size_override("font_size", 12)
	_name_label.add_theme_color_override("font_color", C_FLAME_2)
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_plate.add_child(_name_label)

	_choices = VBoxContainer.new()
	_choices.add_theme_constant_override("separation", 6)
	add_child(_choices)
	_choices.anchor_left = 0.0
	_choices.anchor_right = 1.0
	_choices.anchor_top = 1.0
	_choices.anchor_bottom = 1.0
	_choices.offset_left = 28
	_choices.offset_right = -28
	_choices.offset_top = -196
	_choices.offset_bottom = -196
	_choices.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_choices.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_file_button = _make_button("Fascicolo")
	_file_button.add_theme_font_size_override("font_size", 11)
	_file_button.pressed.connect(_on_file_pressed)
	add_child(_file_button)
	_file_button.anchor_left = 1.0
	_file_button.anchor_right = 1.0
	_file_button.offset_left = -92
	_file_button.offset_right = -8
	_file_button.offset_top = 8
	_file_button.offset_bottom = 36

	_fade = ColorRect.new()
	_fade.color = C_NIGHT_0
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _open_overlay() -> VBoxContainer:
	_close_overlay()
	_overlay = ColorRect.new()
	(_overlay as ColorRect).color = Color(C_NIGHT_0, 0.85)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	move_child(_overlay, _fade.get_index())
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	_overlay.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	var sb := StyleBoxTexture.new()
	sb.texture = load(PANEL_TEX)
	sb.set_texture_margin_all(16)
	sb.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", sb)
	panel.custom_minimum_size.x = 316
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	return box


func _close_overlay() -> void:
	if _overlay:
		_overlay.queue_free()
		_overlay = null


func _add_label(parent: Control, text: String, font_size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	parent.add_child(lbl)
	return lbl


func _make_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size.y = 40
	return b


## Stesso tema provvisorio di PuzzleTest (legno e fiamma della palette).
func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 12
	var states := {
		"normal": [C_WOOD_1, C_WOOD_3],
		"hover": [C_WOOD_2, C_WOOD_4],
		"pressed": [C_WOOD_3, C_FLAME_1],
		"disabled": [C_NIGHT_1, C_WOOD_1],
	}
	for state in states:
		var sb := StyleBoxFlat.new()
		sb.bg_color = states[state][0]
		sb.border_color = states[state][1]
		sb.set_border_width_all(1)
		sb.set_content_margin_all(6)
		t.set_stylebox(state, "Button", sb)
	t.set_stylebox("hover_pressed", "Button", t.get_stylebox("pressed", "Button"))
	t.set_color("font_color", "Button", C_TEXT)
	t.set_color("font_hover_color", "Button", C_TEXT)
	t.set_color("font_pressed_color", "Button", C_FLAME_2)
	t.set_color("font_hover_pressed_color", "Button", C_FLAME_2)
	t.set_color("font_disabled_color", "Button", C_NIGHT_6)
	t.set_color("font_color", "Label", C_TEXT)
	return t
