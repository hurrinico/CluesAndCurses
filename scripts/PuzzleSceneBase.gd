class_name PuzzleSceneBase
extends Control

## Base comune delle scene dei nuovi enigmi (GDD #07): Sigillo Runico e Cime Aggrovigliate.
## Offre la stessa interfaccia di PuzzleTest (la scena del Picross), così CaseScene le usa
## tutte allo stesso modo: prima di add_child si impostano case_path, forced_index e
## background_texture; alla chiusura della schermata della prova ottenuta emette finished.
##
## Gerarchia costruita in _build_frame():
## <Scena> (Control, sottoclasse di questo script)
## ├── Background (ColorRect + sfondo della scena scurito)
## ├── Margin (MarginContainer)
## │   └── Main (VBoxContainer)
## │       ├── CaseLabel, ClueLabel, InfoLabel   (intestazione, come PuzzleTest)
## │       ├── RulesLabel                         (la regola in una riga)
## │       ├── StatusRow (Concentrazione + integrità)
## │       ├── [tabellone: _build_board()]       (si espande)
## │       ├── [comandi:  _build_controls()]
## │       └── RestartButton
## └── Overlay (creato al bisogno: Patto Oscuro, prova ottenuta)
##
## Una sottoclasse implementa: _create_core(), _build_board(), _bind_board(),
## _build_controls(), _refresh_controls(), _play_victory() e i testi _kind_label()/_rules_text().

signal finished

const PANEL_TEX := "res://assets/ui/U4_pannello_dialogo.png"
const PACT_TEX := "res://assets/ui/U6_cornice_patto.png"
const INK_ICON := "res://assets/ui/U5_inchiostro_corrotto.png"
const HINT_ICON := "res://assets/tiles/icon_hint.png"

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

var case_path: String = "res://data/cases/case_01.json"
var forced_index: int = -1               # indice del puzzle nel caso (-1 = il primo del tipo giusto)
var background_texture: Texture2D

var case_data: Dictionary = {}
var puzzle: Dictionary = {}
var core: Node

var _main: VBoxContainer
var _case_label: Label
var _clue_label: Label
var _info_label: Label
var _rules_label: Label
var _hp_label: Label
var _integrity_label: Label
var _restart_button: Button
var _overlay: Control


# =====================================================================
# 1. AVVIO
# =====================================================================
func _ready() -> void:
	theme = make_theme()
	_build_frame()
	case_data = CaseLoader.load_case(case_path)
	if case_data.is_empty():
		_clue_label.text = "Errore nel caricamento del caso"
		return
	var index := forced_index
	if index < 0:
		for i in case_data["puzzles"].size():
			if CaseLoader.puzzle_type(case_data["puzzles"][i]) == _puzzle_type():
				index = i
				break
	if index < 0:
		_clue_label.text = "Nessun enigma di questo tipo nel caso"
		return
	forced_index = index
	puzzle = case_data["puzzles"][index]
	_case_label.text = case_data.get("title", "")
	_rules_label.text = _rules_text()
	_build_board(_main)
	_build_controls(_main)
	_restart_button = _add_button(_main, "Ricomincia enigma", _on_restart_pressed)
	_restart_button.add_theme_font_size_override("font_size", 10)
	_load(true)


## Crea (o ricrea) il core, riprende il salvataggio se c'è e collega il tabellone.
func _load(resume: bool) -> void:
	_close_overlay()
	var old := core
	core = _create_core(puzzle)
	add_child(core)
	if resume:
		var state: Dictionary = SaveManager.get_saved_state_for(case_data["case_id"], puzzle["puzzle_id"])
		if not state.is_empty():
			core.load_state(state)
	core.puzzle_solved.connect(_on_solved)
	core.concentration_depleted.connect(_refresh_hud)
	_bind_board()
	if old:
		old.queue_free()
	_refresh_hud()


# =====================================================================
# 2. DA IMPLEMENTARE NELLE SOTTOCLASSI
# =====================================================================
func _puzzle_type() -> String:
	return ""


func _kind_label() -> String:
	return ""


func _rules_text() -> String:
	return ""


func _create_core(_p: Dictionary) -> Node:
	return null


func _build_board(_parent: VBoxContainer) -> void:
	pass


func _bind_board() -> void:
	pass


func _build_controls(_parent: VBoxContainer) -> void:
	pass


func _refresh_controls() -> void:
	pass


## Animazione di vittoria del tabellone (await-abile).
func _play_victory() -> void:
	await get_tree().create_timer(0.3).timeout


func _info_suffix() -> String:
	return ""


# =====================================================================
# 3. EVENTI COMUNI
# =====================================================================
## Da chiamare dopo ogni mossa: salvataggio differito dell'enigma in corso.
func save_progress() -> void:
	if core and not core.is_completed:
		SaveManager.save_puzzle_state(case_data["case_id"], puzzle["puzzle_id"], core)
	_refresh_hud()


func _on_solved() -> void:
	var clue: Dictionary = puzzle["reward_clue"]
	SaveManager.record_clue(clue["clue_id"], core)
	_refresh_hud()
	await _play_victory()
	_show_result(clue)


func _on_restart_pressed() -> void:
	SaveManager.clear_puzzle_state()
	_load(false)


## Aiuto: lo applica la sottoclasse con il proprio core (toglie la terza stella).
func _on_hint_pressed() -> void:
	pass


# --- Inchiostro Corrotto: mai accidentale (GDD #04, sezione 5) ---
func _on_ink_pressed() -> void:
	if core == null or core.is_completed:
		return
	var box := _open_overlay(true)
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
# 4. HUD
# =====================================================================
func _refresh_hud() -> void:
	if core == null or puzzle.is_empty():
		return
	var clue: Dictionary = puzzle["reward_clue"]
	var identified: bool = core.is_completed or SaveManager.has_clue(clue["clue_id"])
	_clue_label.text = clue["name"] if identified else clue["unidentified_name"]
	_info_label.text = "%s · %s%s" % [puzzle.get("puzzle_title", ""), _kind_label(), _info_suffix()]
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
	_restart_button.disabled = core.is_completed
	_refresh_controls()


## Schermata della prova ottenuta (identica a quella del Picross).
func _show_result(clue: Dictionary) -> void:
	var box := _open_overlay(false)
	_add_label(box, "PROVA OTTENUTA", 12, C_FLAME_1)
	var sprite_path: String = clue.get("sprite_path", "")
	if sprite_path != "" and ResourceLoader.exists(sprite_path):
		var pic := TextureRect.new()
		pic.texture = load(sprite_path)
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.custom_minimum_size = Vector2(128, 128)
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
	_add_button(box, "Continua", func(): finished.emit())


# =====================================================================
# 5. COSTRUZIONE DELLA CORNICE
# =====================================================================
func _build_frame() -> void:
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
		pic.modulate = Color(0.35, 0.33, 0.45)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(pic)
		pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_main = VBoxContainer.new()
	_main.add_theme_constant_override("separation", 6)
	margin.add_child(_main)

	_case_label = _add_label(_main, "", 10, C_FLAME_1)
	_clue_label = _add_label(_main, "", 18, C_TEXT)
	_info_label = _add_label(_main, "", 10, C_NIGHT_6)
	_rules_label = _add_label(_main, "", 10, C_NIGHT_7)

	var status := HBoxContainer.new()
	_main.add_child(status)
	_hp_label = _add_label(status, "", 12, C_FLAME_2)
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_hp_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_integrity_label = _add_label(status, "", 12, C_NIGHT_6)
	_integrity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_integrity_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _open_overlay(pact: bool) -> VBoxContainer:
	_close_overlay()
	_overlay = ColorRect.new()
	(_overlay as ColorRect).color = Color(C_NIGHT_0, 0.85)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	_overlay.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", make_frame_style(PACT_TEX if pact else PANEL_TEX, C_NIGHT_1))
	panel.custom_minimum_size.x = 300
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	return box


func _close_overlay() -> void:
	if _overlay:
		_overlay.queue_free()
		_overlay = null


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


## Pulsanti Aiuto e Inchiostro, comuni a tutti i nuovi enigmi.
func _add_hint_and_ink(row: HBoxContainer) -> Array[Button]:
	var hint := _add_button(row, "Aiuto", _on_hint_pressed)
	if ResourceLoader.exists(HINT_ICON):
		hint.icon = load(HINT_ICON)
	var ink := _add_button(row, "Inchiostro", _on_ink_pressed)
	ink.add_theme_color_override("font_color", C_ARCANE_2)
	if ResourceLoader.exists(INK_ICON):
		ink.icon = load(INK_ICON)
	for b in [hint, ink]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size.y = 44
		b.expand_icon = false
	return [hint, ink]


## Stesso tema di PuzzleTest (legno e fiamma della palette).
static func make_theme() -> Theme:
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
