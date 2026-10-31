extends Control

## Tavolo delle Mappe (GDD #02, Sanctum): elenco dei casi con stato e stelle.
## Un caso si sblocca quando quello indicato in "requires_case" è stato concluso.
## Toccando un caso sbloccato si imposta current_case_id e si apre CaseScene.
##
## Gerarchia costruita in _build():
## CaseSelect (Control, questo script)
## ├── Background (TextureRect, Sanctum scurito)
## └── Margin > VBox
##     ├── Titolo + sottotitolo
##     ├── Una scheda per caso (PanelContainer: pulsante sotto, testi sopra)
##     └── Pulsante "Titolo"

const CASE_IDS := ["case_01", "case_02"]
const CASE_SCENE := "res://scenes/CaseScene.tscn"
const TITLE_SCENE := "res://scenes/TitleScreen.tscn"
const BG_PATH := "res://assets/backgrounds/B3_sanctum.png"
const CaseSceneScript := preload("res://scenes/CaseScene.gd")

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
const C_ARCANE_2 := Color("a050b0")

var cards: Array = []     # per i test: [{case_id, unlocked, button}]
var account_button: Button  # per i test
var _list: VBoxContainer
var _fade: ColorRect


func _ready() -> void:
	theme = _make_theme()
	_build()
	_fill()
	var t := create_tween()
	t.tween_property(_fade, "color:a", 0.0, 0.5)


## Stato di un caso: "locked", "new", "progress", "done".
static func case_state(data: Dictionary) -> String:
	var cid: String = data["case_id"]
	var req: String = data.get("requires_case", "")
	if req != "" and not _is_done(req):
		return "locked"
	if _is_done(cid):
		return "done"
	return "progress" if SaveManager.get_case_step(cid) > 0 else "new"


## Concluso: segnato da CaseScene, oppure (salvataggi precedenti) arrivato all'ultimo passo.
static func _is_done(cid: String) -> bool:
	if SaveManager.is_case_completed(cid):
		return true
	var data := CaseLoader.load_case("res://data/cases/%s.json" % cid)
	if data.is_empty():
		return false
	return SaveManager.get_case_step(cid) >= CaseSceneScript.build_steps(data).size()


func open_case(case_id: String) -> void:
	SaveManager.game_data["current_case_id"] = case_id
	SaveManager.save_game()
	var t := create_tween()
	t.tween_property(_fade, "color:a", 1.0, 0.4)
	t.tween_callback(func(): get_tree().change_scene_to_file(CASE_SCENE))


func _fill() -> void:
	for c in _list.get_children():
		c.queue_free()
	cards.clear()
	for cid in CASE_IDS:
		var data := CaseLoader.load_case("res://data/cases/%s.json" % cid)
		if data.is_empty():
			continue
		var state := case_state(data)
		_list.add_child(_case_card(data, state))


func _case_card(data: Dictionary, state: String) -> Control:
	var cid: String = data["case_id"]
	var holder := PanelContainer.new()
	holder.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.disabled = state == "locked"
	b.pressed.connect(open_case.bind(cid))
	holder.add_child(b)
	cards.append({"case_id": cid, "state": state, "button": b})

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	holder.add_child(margin)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 3)
	margin.add_child(col)

	var dim := state == "locked"
	_label(col, "CASO #%02d · %s" % [int(data.get("case_number", CASE_IDS.find(cid) + 1)), data.get("district", "")],
			10, C_NIGHT_6 if dim else C_FLAME_1)
	_label(col, data.get("title", cid), 15, C_NIGHT_6 if dim else C_TEXT)
	var status := ""
	var color := C_NIGHT_7
	match state:
		"locked":
			var req: String = data.get("requires_case", "")
			status = "Bloccato: risolvi prima il caso #%s" % req.trim_prefix("case_")
		"new":
			status = "Nuovo caso: tocca per iniziare"
			color = C_FLAME_2
		"progress":
			status = "Indagine in corso: tocca per riprendere"
			color = C_FLAME_2
		"done":
			var stars := 0
			for puzzle in data["puzzles"]:
				stars += int(SaveManager.game_data["clues"].get(puzzle["reward_clue"]["clue_id"], {}).get("stars", 0))
			status = "Caso chiuso · stelle %d su %d" % [stars, data["puzzles"].size() * 3]
			var choice: Dictionary = SaveManager.game_data["moral"]["case_choices"].get(cid, {})
			if not choice.is_empty():
				for opt in data.get("final_choice", {}).get("options", []):
					if opt["choice"] == choice.get("choice", ""):
						status += "\nScelta: " + opt["label"]
	_label(col, status, 11, color)
	return holder


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var base := ColorRect.new()
	base.color = C_NIGHT_0
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(base)
	base.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bg := TextureRect.new()
	bg.texture = load(BG_PATH)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.modulate = Color(0.45, 0.42, 0.55)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	margin.add_theme_constant_override("margin_top", 40)
	margin.add_theme_constant_override("margin_bottom", 20)
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var main := VBoxContainer.new()
	main.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main.add_theme_constant_override("separation", 10)
	margin.add_child(main)
	_label(main, "TAVOLO DELLE MAPPE", 12, C_FLAME_1).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label(main, "Oakhaven attende il suo Inquisitore", 11, C_NIGHT_7).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_list = VBoxContainer.new()
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.add_theme_constant_override("separation", 10)
	main.add_child(_list)

	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(spacer)
	# Accesso: visibile solo nel browser con Supabase configurato (AuthService)
	account_button = Button.new()
	account_button.focus_mode = Control.FOCUS_NONE
	account_button.custom_minimum_size.y = 40
	account_button.pressed.connect(func(): AuthService.open_panel())
	main.add_child(account_button)
	AuthService.state_changed.connect(_on_auth_state)
	AuthService.save_replaced.connect(_fill)
	_update_account()

	var back := Button.new()
	back.text = "Schermata iniziale"
	back.focus_mode = Control.FOCUS_NONE
	back.custom_minimum_size.y = 40
	back.pressed.connect(func(): get_tree().change_scene_to_file(TITLE_SCENE))
	main.add_child(back)

	_fade = ColorRect.new()
	_fade.color = C_NIGHT_0
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _on_auth_state(_state: Dictionary) -> void:
	_update_account()


func _update_account() -> void:
	account_button.visible = AuthService.is_available()
	if AuthService.is_signed_in():
		account_button.text = "Inquisitore %s · Profilo" % AuthService.display_name()
	else:
		account_button.text = "Accedi · salva le indagini nel cloud"


func _label(parent: Control, text: String, font_size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	parent.add_child(lbl)
	return lbl


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 12
	var states := {
		"normal": [Color(C_WOOD_1, 0.92), C_WOOD_3],
		"hover": [Color(C_WOOD_2, 0.95), C_WOOD_4],
		"pressed": [C_WOOD_3, C_FLAME_1],
		"disabled": [Color(C_NIGHT_1, 0.85), C_WOOD_1],
	}
	for state in states:
		var sb := StyleBoxFlat.new()
		sb.bg_color = states[state][0]
		sb.border_color = states[state][1]
		sb.set_border_width_all(1)
		sb.set_content_margin_all(6)
		t.set_stylebox(state, "Button", sb)
	t.set_color("font_color", "Button", C_TEXT)
	t.set_color("font_disabled_color", "Button", C_NIGHT_6)
	return t
