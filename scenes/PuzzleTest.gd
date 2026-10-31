extends Control

## Scena di prova del Caso #01: le tre prove Picross con HUD completa.
## Collega CaseLoader -> PicrossCore -> PicrossGridUI -> SaveManager.
##
## Gerarchia costruita in _build_ui():
## PuzzleTest (Control, questo script)
## ├── Background (ColorRect)
## ├── Margin (MarginContainer)
## │   └── Main (VBoxContainer)
## │       ├── CaseLabel, ClueLabel, InfoLabel   (intestazione)
## │       ├── Tabs (HBox: Prova 1 / 2 / 3)
## │       ├── StatusRow (Concentrazione + integrità)
## │       ├── PicrossGridUI                     (si espande)
## │       ├── ActionRow (Riempi/X, Annulla, Inchiostro)
## │       └── RestartButton
## └── Overlay (creato al bisogno: Patto Oscuro, prova ottenuta)
##
## Modalità caso (usata da CaseScene): prima di add_child impostare forced_index
## (e facoltativamente background_texture). Le schede sono nascoste, dietro la griglia
## c'è lo sfondo della scena e la schermata della prova ottenuta mostra l'illustrazione
## dell'oggetto con il pulsante "Continua", che emette finished.

const CASE_PATH := "res://data/cases/case_01.json"
const TILE_EMPTY := "res://assets/tiles/cell_empty.png"
const TILE_FILLED := "res://assets/tiles/cell_filled.png"
const TILE_MARKED := "res://assets/tiles/cell_marked.png"
const PANEL_TEX := "res://assets/ui/U4_pannello_dialogo.png"
const PACT_TEX := "res://assets/ui/U6_cornice_patto.png"
const INK_ICON := "res://assets/ui/U5_inchiostro_corrotto.png"

signal finished    # modalità caso: il giocatore ha chiuso la schermata della prova ottenuta

var case_path: String = CASE_PATH        # modalità caso: il file del caso in corso
var forced_index: int = -1               # >= 0: modalità caso, una sola prova
var background_texture: Texture2D        # sfondo scurito dietro la griglia (modalità caso)

# --- Palette Clues & Curses (GDD #05) ---
const C_NIGHT_0 := Color("0b0a12")
const C_NIGHT_1 := Color("14121f")
const C_NIGHT_6 := Color("56607e")
const C_WOOD_1 := Color("33201a")
const C_WOOD_2 := Color("4a2e21")
const C_WOOD_3 := Color("66412b")
const C_WOOD_4 := Color("85593a")
const C_FLAME_1 := Color("dba04a")
const C_FLAME_2 := Color("f0c060")
const C_TEXT := Color("fff4cc")
const C_BLOOD := Color("cc3a2e")
const C_ARCANE_0 := Color("3a1d4a")
const C_ARCANE_2 := Color("a050b0")

var case_data: Dictionary = {}
var puzzles: Array = []
var current_index: int = 0
var core: PicrossCore
var grid: PicrossGridUI

# --- HUD ---
var _case_label: Label
var _clue_label: Label
var _info_label: Label
var _hp_label: Label
var _integrity_label: Label
var _tabs: Array[Button] = []
var _mode_button: Button
var _undo_button: Button
var _ink_button: Button
var _restart_button: Button
var _overlay: Control


# =====================================================================
# 1. AVVIO
# =====================================================================
func _ready() -> void:
	theme = _make_theme()
	_build_ui()

	case_data = CaseLoader.load_case(case_path)
	if case_data.is_empty():
		_clue_label.text = "Errore nel caricamento del caso"
		return
	puzzles = case_data["puzzles"]
	_case_label.text = case_data["title"]
	for i in _tabs.size():
		_tabs[i].visible = i < puzzles.size()

	if forced_index >= 0:
		for t in _tabs:
			t.visible = false
		_load_puzzle(forced_index, true)
	else:
		_load_puzzle(_pick_start_index(), true)


## Riprende il puzzle in corso se c'è, altrimenti la prima prova non ancora ottenuta.
## Solo griglie Picross: gli altri tipi di enigma hanno la loro scena.
func _pick_start_index() -> int:
	if SaveManager.has_active_puzzle():
		var active: Dictionary = SaveManager.game_data["active_puzzle"]
		if active.get("case_id", "") == case_data["case_id"]:
			for i in puzzles.size():
				if puzzles[i]["puzzle_id"] == active["puzzle_id"] and CaseLoader.puzzle_type(puzzles[i]) == "picross":
					return i
	for i in puzzles.size():
		if CaseLoader.puzzle_type(puzzles[i]) == "picross" and not SaveManager.has_clue(puzzles[i]["reward_clue"]["clue_id"]):
			return i
	for i in puzzles.size():
		if CaseLoader.puzzle_type(puzzles[i]) == "picross":
			return i
	return 0


func _load_puzzle(index: int, resume: bool) -> void:
	_close_overlay()
	current_index = index
	var puzzle: Dictionary = puzzles[index]

	var old_core := core
	core = PicrossCore.new()
	add_child(core)
	core.setup_puzzle(puzzle["solution_matrix"], int(puzzle.get("max_hp", 3)))
	var fog: Dictionary = puzzle.get("fog", {})
	core.setup_fog(fog.get("rows", []), fog.get("cols", []))

	var active: Dictionary = SaveManager.game_data["active_puzzle"]
	if resume and active.get("puzzle_id", "") == puzzle["puzzle_id"]:
		core.load_state(SaveManager.get_active_puzzle_state())

	core.cell_changed.connect(_on_cell_changed)
	core.error_committed.connect(func(_r, _c, _hp): _refresh_hud())
	core.concentration_depleted.connect(_refresh_hud)
	core.undo_availability_changed.connect(func(_v): _refresh_hud())
	core.puzzle_solved.connect(_on_puzzle_solved)

	grid.bind_core(core)
	if old_core:
		old_core.queue_free()
	_refresh_hud()


# =====================================================================
# 2. EVENTI DI GIOCO
# =====================================================================
func _on_cell_changed(_r: int, _c: int, _s: int) -> void:
	if not core.is_completed:
		SaveManager.save_puzzle_state(case_data["case_id"], puzzles[current_index]["puzzle_id"], core)
	_refresh_hud()


func _on_puzzle_solved() -> void:
	var clue: Dictionary = puzzles[current_index]["reward_clue"]
	SaveManager.record_clue(clue["clue_id"], core)
	_refresh_hud()
	await grid.reveal_finished
	_show_result(clue)


func _on_mode_pressed() -> void:
	grid.toggle_input_mode()
	_refresh_hud()


func _on_undo_pressed() -> void:
	grid.undo()
	_refresh_hud()


func _on_restart_pressed() -> void:
	SaveManager.clear_puzzle_state()
	_load_puzzle(current_index, false)


func _on_tab_pressed(index: int) -> void:
	if index != current_index:
		_load_puzzle(index, true)
	else:
		_refresh_hud()


# --- Inchiostro Corrotto: mai accidentale (GDD #04, sezione 5) ---
func _on_ink_pressed() -> void:
	var box := _open_overlay(C_ARCANE_2, C_NIGHT_0)
	_add_label(box, "PATTO OSCURO", 18, C_ARCANE_2)
	_add_label(box, "Utilizzare l'Inchiostro Corrotto spezzerà il sigillo della tua Inquisizione, marchiando la tua indagine con la forza dell'eresia.\n\nVuoi accettare il potere oscuro in cambio della soluzione immediata?", 11, C_TEXT)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	var refuse := _add_button(row, "Rifiuta", _close_overlay)
	refuse.custom_minimum_size.x = 110
	var accept := _add_button(row, "Accetta il Patto", _accept_pact)
	accept.custom_minimum_size.x = 130
	accept.add_theme_color_override("font_color", C_ARCANE_2)


func _accept_pact() -> void:
	_close_overlay()
	SaveManager.register_dark_pact()
	core.apply_corrupted_ink()


# =====================================================================
# 3. HUD
# =====================================================================
func _refresh_hud() -> void:
	if core == null or puzzles.is_empty():
		return
	var puzzle: Dictionary = puzzles[current_index]
	var clue: Dictionary = puzzle["reward_clue"]
	var identified := core.is_completed or SaveManager.has_clue(clue["clue_id"])
	_clue_label.text = clue["name"] if identified else clue["unidentified_name"]
	_info_label.text = "%s · %dx%d" % [puzzle.get("puzzle_title", ""), core.rows, core.cols]
	if puzzle.has("fog"):
		_info_label.text += " · Nebbia Arcanica"

	if core.hp_concentration > 0:
		_hp_label.text = "Concentrazione %d/%d" % [core.hp_concentration, core.max_hp]
		_hp_label.add_theme_color_override("font_color", C_FLAME_2)
	else:
		_hp_label.text = "Concentrazione esaurita"
		_hp_label.add_theme_color_override("font_color", C_BLOOD)

	if core.used_corrupted_ink:
		_integrity_label.text = "Prova contaminata"
		_integrity_label.add_theme_color_override("font_color", C_ARCANE_2)
	elif core.is_damaged:
		_integrity_label.text = "Prova danneggiata"
		_integrity_label.add_theme_color_override("font_color", C_BLOOD)
	else:
		_integrity_label.text = "Prova integra"
		_integrity_label.add_theme_color_override("font_color", C_NIGHT_6)

	_mode_button.text = "Modo: Riempi" if grid.input_mode == PicrossGridUI.InputMode.FILL else "Modo: X"
	_undo_button.disabled = not core.can_undo()
	_ink_button.disabled = core.is_completed
	_mode_button.disabled = core.is_completed

	for i in _tabs.size():
		if i >= puzzles.size():
			continue
		var got := SaveManager.has_clue(puzzles[i]["reward_clue"]["clue_id"])
		_tabs[i].text = "Prova %d%s" % [i + 1, " *" if got else ""]
		_tabs[i].set_pressed_no_signal(i == current_index)
		_tabs[i].disabled = CaseLoader.puzzle_type(puzzles[i]) != "picross"


func _show_result(clue: Dictionary) -> void:
	var box := _open_overlay(C_FLAME_1, C_NIGHT_1)
	_add_label(box, "PROVA OTTENUTA", 12, C_FLAME_1)
	var sprite_path: String = clue.get("sprite_path", "")
	if sprite_path != "" and ResourceLoader.exists(sprite_path):
		var pic := TextureRect.new()
		pic.texture = load(sprite_path)
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.custom_minimum_size = Vector2(128, 128)   # 64x64 a 2x, pixel nitidi
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(pic)
		pic.modulate.a = 0.0
		create_tween().tween_property(pic, "modulate:a", 1.0, 0.6)
	_add_label(box, clue["name"], 18, C_TEXT)
	_add_label(box, clue["description"], 11, C_TEXT)
	var tags := ", ".join(PackedStringArray(clue.get("tags", [])))
	_add_label(box, "[%s]" % tags, 10, C_NIGHT_6)

	var integrity := "Integra"
	var color := C_FLAME_2
	if core.used_corrupted_ink:
		integrity = "Contaminata (Patto Oscuro)"
		color = C_ARCANE_2
	elif core.is_damaged:
		integrity = "Danneggiata: il sospettato la contesterà"
		color = C_BLOOD
	_add_label(box, "Integrità: " + integrity, 11, color)
	_add_label(box, "Stelle: %d/3   ·   Errori: %d" % [core.get_stars(), core.errors_count], 11, C_TEXT)
	_add_label(box, "Punteggio morale: %d" % SaveManager.get_morality_score(), 10, C_NIGHT_6)

	if forced_index >= 0:
		_add_button(box, "Continua", func(): finished.emit())
		return
	var next := _next_unsolved_index()
	if next >= 0:
		_add_button(box, "Prossima prova", func(): _load_puzzle(next, true))
	else:
		_add_label(box, "Tutte le prove del caso sono state raccolte.\nProssimo modulo: gli interrogatori.", 11, C_FLAME_2)
		_add_button(box, "Chiudi", _close_overlay)


func _next_unsolved_index() -> int:
	for step in range(1, puzzles.size() + 1):
		var i := (current_index + step) % puzzles.size()
		if CaseLoader.puzzle_type(puzzles[i]) == "picross" and not SaveManager.has_clue(puzzles[i]["reward_clue"]["clue_id"]):
			return i
	return -1


# =====================================================================
# 4. COSTRUZIONE DELLA UI
# =====================================================================
func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = C_NIGHT_0
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	if background_texture:
		var pic := TextureRect.new()
		pic.texture = background_texture
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		pic.modulate = Color(0.35, 0.33, 0.45)   # scurito: la griglia resta leggibile
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(pic)
		pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var main := VBoxContainer.new()
	main.add_theme_constant_override("separation", 6)
	margin.add_child(main)

	_case_label = _add_label(main, "", 10, C_FLAME_1)
	_clue_label = _add_label(main, "", 18, C_TEXT)
	_info_label = _add_label(main, "", 10, C_NIGHT_6)

	var tabs_row := HBoxContainer.new()
	tabs_row.add_theme_constant_override("separation", 4)
	main.add_child(tabs_row)
	for i in 3:
		var tab := _add_button(tabs_row, "Prova %d" % (i + 1), _on_tab_pressed.bind(i))
		tab.toggle_mode = true
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_tabs.append(tab)

	var status := HBoxContainer.new()
	main.add_child(status)
	_hp_label = _add_label(status, "", 12, C_FLAME_2)
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_hp_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_integrity_label = _add_label(status, "", 12, C_NIGHT_6)
	_integrity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_integrity_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	grid = PicrossGridUI.new()
	grid.tex_empty = load(TILE_EMPTY)
	grid.tex_filled = load(TILE_FILLED)
	grid.tex_marked = load(TILE_MARKED)
	grid.block_tint = Color(0.88, 0.9, 1.0)
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.input_mode_changed.connect(func(_m): _refresh_hud())
	main.add_child(grid)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 4)
	main.add_child(actions)
	_mode_button = _add_button(actions, "Modo: Riempi", _on_mode_pressed)
	_undo_button = _add_button(actions, "Annulla", _on_undo_pressed)
	_ink_button = _add_button(actions, "Inchiostro", _on_ink_pressed)
	_ink_button.add_theme_color_override("font_color", C_ARCANE_2)
	_ink_button.icon = load(INK_ICON)
	_ink_button.expand_icon = false
	for b in [_mode_button, _undo_button, _ink_button]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size.y = 44   # area di tocco minima consigliata

	_restart_button = _add_button(main, "Ricomincia puzzle", _on_restart_pressed)
	_restart_button.add_theme_font_size_override("font_size", 10)


func _open_overlay(border: Color, bg: Color) -> VBoxContainer:
	_close_overlay()
	_overlay = ColorRect.new()
	(_overlay as ColorRect).color = Color(C_NIGHT_0, 0.85)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP   # blocca la griglia sotto
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	_overlay.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var panel := PanelContainer.new()
	var tex_path := PACT_TEX if border == C_ARCANE_2 else PANEL_TEX
	panel.add_theme_stylebox_override("panel", make_frame_style(tex_path, bg))
	panel.custom_minimum_size.x = 300
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	return box


## Cornice 9-slice dagli asset U4/U6 (48x48 e 64x64: angoli di 16 px).
static func make_frame_style(tex_path: String, fallback_bg: Color) -> StyleBox:
	if ResourceLoader.exists(tex_path):
		var sb := StyleBoxTexture.new()
		sb.texture = load(tex_path)
		sb.set_texture_margin_all(16)
		sb.set_content_margin_all(16)
		return sb
	var flat := StyleBoxFlat.new()
	flat.bg_color = fallback_bg
	flat.set_content_margin_all(14)
	return flat


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


func _add_button(parent: Control, text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(callback)
	parent.add_child(btn)
	return btn


## Tema provvisorio nei colori della palette, finché non arrivano gli asset di GDD #05.
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
