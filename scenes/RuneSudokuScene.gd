extends PuzzleSceneBase

## Scena del Sigillo Runico (GDD #07): sudoku classico con le rune al posto dei numeri.
## Si tocca una casella vuota e poi una runa della barra in basso. Con la Matita attiva
## la runa viene solo annotata (nessun costo). Da tastiera: frecce per spostarsi,
## 1-6 per posare una runa, N per la matita, Canc per togliere le annotazioni.
##
## Gerarchia aggiunta alla cornice di PuzzleSceneBase:
## Main
## ├── RuneGridUI            (tabellone, si espande)
## ├── RuneBar (HBox)        (una runa per pulsante: posa o annota)
## └── ActionRow (HBox)      (Matita, Aiuto, Inchiostro)

const RUNE_TEX := "res://assets/tiles/runes/rune_%s_%s.png"

var grid: RuneGridUI
var pencil: bool = false

var _rune_buttons: Array[Button] = []
var _pencil_button: Button
var _hint_button: Button
var _ink_button: Button


func _puzzle_type() -> String:
	return "rune_sudoku"


func _kind_label() -> String:
	var n := int(puzzle.get("size", 4))
	return "Sigillo Runico %dx%d" % [n, n]


func _rules_text() -> String:
	return "Ogni runa compare una sola volta in ogni riga, colonna e riquadro."


func _create_core(p: Dictionary) -> Node:
	var c := RuneSudokuCore.new()
	c.setup_from_puzzle(p)
	return c


func _build_board(parent: VBoxContainer) -> void:
	grid = RuneGridUI.new()
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.custom_minimum_size = Vector2(0, 200)
	grid.cell_selected.connect(_on_cell_selected)
	parent.add_child(grid)


func _bind_board() -> void:
	core.error_committed.connect(func(_r, _c, _v, _hp): _refresh_hud())
	core.rune_completed.connect(func(_v): _refresh_controls())
	grid.bind_core(core, puzzle["runes"])
	_select_first_empty()


func _build_controls(parent: VBoxContainer) -> void:
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 4)
	parent.add_child(bar)
	var runes: Array = puzzle["runes"]
	for i in runes.size():
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(52, 52)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.tooltip_text = String(runes[i]).capitalize()
		b.pressed.connect(_on_rune_pressed.bind(i))
		var pic := TextureRect.new()
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var path := RUNE_TEX % [runes[i], "ink"]
		if ResourceLoader.exists(path):
			pic.texture = load(path)
		b.add_child(pic)
		pic.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		pic.offset_left = -16
		pic.offset_right = 16
		pic.offset_top = -16
		pic.offset_bottom = 16
		bar.add_child(b)
		_rune_buttons.append(b)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 4)
	parent.add_child(actions)
	_pencil_button = _add_button(actions, "Matita: no", _on_pencil_pressed)
	_pencil_button.toggle_mode = true
	_pencil_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pencil_button.custom_minimum_size.y = 44
	var extra := _add_hint_and_ink(actions)
	_hint_button = extra[0]
	_ink_button = extra[1]


func _refresh_controls() -> void:
	if core == null or _rune_buttons.is_empty():
		return
	var done: bool = core.is_completed
	for i in _rune_buttons.size():
		var complete: bool = core.count_placed(i) >= core.size
		_rune_buttons[i].disabled = done or complete
		_rune_buttons[i].modulate.a = 0.45 if complete else 1.0
	_pencil_button.disabled = done
	_pencil_button.set_pressed_no_signal(pencil)
	_pencil_button.text = "Matita: sì" if pencil else "Matita: no"
	_hint_button.disabled = done
	_ink_button.disabled = done


func _info_suffix() -> String:
	return ""


# =====================================================================
# MOSSE
# =====================================================================
func _on_cell_selected(r: int, c: int) -> void:
	grid.set_selected(Vector2i(r, c))
	if not core.is_filled(r, c):
		grid.set_highlight_rune(-1)


func _on_rune_pressed(rune: int) -> void:
	if core.is_completed:
		return
	var sel := grid.selected
	if sel.x < 0 or core.is_filled(sel.x, sel.y):
		grid.set_highlight_rune(rune)   # nessuna casella vuota scelta: mostra dove sta già quella runa
		return
	if pencil:
		core.toggle_note(sel.x, sel.y, rune)
	elif core.place_rune(sel.x, sel.y, rune):
		grid.set_highlight_rune(rune)
	save_progress()


func _on_pencil_pressed() -> void:
	pencil = not pencil
	_refresh_controls()


func _on_hint_pressed() -> void:
	if core.is_completed:
		return
	var h: Vector3i = core.use_hint()
	if h.x >= 0:
		grid.set_selected(Vector2i(h.x, h.y))
		grid.set_highlight_rune(h.z)
	save_progress()


func _select_first_empty() -> void:
	for r in core.size:
		for c in core.size:
			if not core.is_filled(r, c):
				grid.set_selected(Vector2i(r, c))
				return


func _play_victory() -> void:
	grid.play_victory()
	await grid.reveal_finished


# --- Tastiera (browser su PC) ---
func _unhandled_key_input(event: InputEvent) -> void:
	if _overlay != null or core == null or core.is_completed:
		return
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	var sel := grid.selected
	if sel.x < 0:
		sel = Vector2i(0, 0)
	match k.keycode:
		KEY_UP: sel.x = posmod(sel.x - 1, core.size)
		KEY_DOWN: sel.x = posmod(sel.x + 1, core.size)
		KEY_LEFT: sel.y = posmod(sel.y - 1, core.size)
		KEY_RIGHT: sel.y = posmod(sel.y + 1, core.size)
		KEY_N:
			_on_pencil_pressed()
			return
		KEY_DELETE, KEY_BACKSPACE:
			core.clear_notes(sel.x, sel.y)
			save_progress()
			return
		_:
			var n := int(k.keycode) - KEY_1
			if n < 0 or n >= core.size:
				n = int(k.keycode) - KEY_KP_1
			if n >= 0 and n < core.size:
				_on_rune_pressed(n)
			return
	_on_cell_selected(sel.x, sel.y)
	get_viewport().set_input_as_handled()
