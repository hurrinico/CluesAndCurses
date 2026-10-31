class_name RuneGridUI
extends Control

## Vista del Sigillo Runico (la "View" del pattern MVC, GDD #07).
## Disegna la griglia con _draw (tessere 16x16 ingrandite a multipli interi: pixel nitidi),
## legge lo stato da RuneSudokuCore e si aggiorna solo tramite i suoi segnali.
## Le mosse (posare una runa, annotare) le decide la scena: qui si seleziona la casella.
##
## Input: tap/clic su una casella -> cell_selected(riga, colonna).

signal cell_selected(row: int, col: int)
signal reveal_finished

const TILE_EMPTY := "res://assets/tiles/cell_empty.png"
const RUNE_TEX := "res://assets/tiles/runes/rune_%s_%s.png"

@export var max_cell_px: int = 96
@export var snap_cell_to_px: int = 16
@export var haptics_enabled: bool = true

# --- Palette ---
const C_NIGHT_0 := Color("0b0a12")
const C_NIGHT_4 := Color("313552")
const C_NIGHT_6 := Color("56607e")
const C_FLAME_0 := Color("c2803a")
const C_FLAME_2 := Color("f0c060")
const C_FLAME_3 := Color("ffe08a")
const C_BLOOD := Color("cc3a2e")
const C_ARCANE_1 := Color("6b2f7a")

var core: RuneSudokuCore
var rune_names: Array = []
var selected: Vector2i = Vector2i(-1, -1)
var highlight_rune: int = -1      # caselle con la stessa runa leggermente evidenziate

var _cell_px: int = 64
var _origin: Vector2 = Vector2.ZERO
var _tex_cell: Texture2D
var _tex: Dictionary = {}           # "nome/stato" -> Texture2D
var _error_cell: Vector2i = Vector2i(-1, -1)
var _error_rune: int = -1
var _error_alpha: float = 0.0
var _flash_cell: Vector2i = Vector2i(-1, -1)   # runa appena posata (o data da un aiuto)
var _flash_alpha: float = 0.0
var _lit: Dictionary = {}            # caselle già accese dall'animazione di vittoria
var _input_enabled := true


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	resized.connect(_layout)
	if ResourceLoader.exists(TILE_EMPTY):
		_tex_cell = load(TILE_EMPTY)


func bind_core(new_core: RuneSudokuCore, runes: Array) -> void:
	if core and core.cell_changed.is_connected(_on_cell_changed):
		core.cell_changed.disconnect(_on_cell_changed)
		core.notes_changed.disconnect(_on_notes_changed)
		core.error_committed.disconnect(_on_error)
	core = new_core
	rune_names = runes
	_tex.clear()
	for name in rune_names:
		for state in ["carved", "ink", "lit", "error"]:
			var path := RUNE_TEX % [name, state]
			if ResourceLoader.exists(path):
				_tex["%s/%s" % [name, state]] = load(path)
	core.cell_changed.connect(_on_cell_changed)
	core.notes_changed.connect(_on_notes_changed)
	core.error_committed.connect(_on_error)
	selected = Vector2i(-1, -1)
	highlight_rune = -1
	_lit.clear()
	_input_enabled = not core.is_completed
	if core.is_completed:
		for r in core.size:
			for c in core.size:
				_lit[Vector2i(r, c)] = true
	_layout()


func set_selected(cell: Vector2i) -> void:
	selected = cell
	if cell.x >= 0 and core.is_filled(cell.x, cell.y):
		highlight_rune = core.player[cell.x][cell.y]
	queue_redraw()


func set_highlight_rune(rune: int) -> void:
	highlight_rune = rune
	queue_redraw()


func cell_px() -> int:
	return _cell_px


# =====================================================================
# LAYOUT E DISEGNO
# =====================================================================
@warning_ignore("integer_division")
func _layout() -> void:
	if core == null or core.size == 0:
		return
	var avail := mini(int(size.x), int(size.y)) - 8
	var px := clampi(avail / core.size, 12, max_cell_px)
	if snap_cell_to_px > 0 and px >= snap_cell_to_px:
		px = (px / snap_cell_to_px) * snap_cell_to_px
	_cell_px = px
	var board := Vector2(px * core.size, px * core.size)
	_origin = ((size - board) / 2.0).floor()
	queue_redraw()


func _draw() -> void:
	if core == null or core.size == 0:
		return
	var n := core.size
	var px := float(_cell_px)
	var board := Rect2(_origin, Vector2(px * n, px * n))
	draw_rect(board.grow(3), C_NIGHT_0)
	for r in n:
		for c in n:
			var rect := Rect2(_origin + Vector2(c * px, r * px), Vector2(px, px))
			if _tex_cell:
				draw_texture_rect(_tex_cell, rect, false)
			else:
				draw_rect(rect, Color("1c1b2e"))
			var cell := Vector2i(r, c)
			var v: int = core.player[r][c]
			# evidenze: riga/colonna/riquadro della selezione, rune uguali, selezione
			if selected.x >= 0 and _same_group(cell, selected) and cell != selected:
				draw_rect(rect, Color(C_NIGHT_4, 0.45))
			if highlight_rune >= 0 and v == highlight_rune:
				draw_rect(rect, Color(C_FLAME_0, 0.18))
			if v >= 0:
				var state := "carved" if core.is_given(r, c) else "ink"
				if _lit.has(cell):
					state = "lit"
				_draw_rune(v, state, rect, 1.0)
				if cell == _flash_cell and _flash_alpha > 0.0:
					_draw_rune(v, "lit", rect, _flash_alpha)
			elif core.notes[r][c] != 0:
				_draw_notes(r, c, rect)
			if cell == _error_cell and _error_alpha > 0.0:
				draw_rect(rect, Color(C_BLOOD, 0.25 * _error_alpha))
				_draw_rune(_error_rune, "error", rect, _error_alpha)
	# linee dei riquadri (2 px, ottone scuro) sopra le celle
	for i in range(0, n + 1):
		if i % core.box_cols == 0:
			draw_rect(Rect2(_origin + Vector2(i * px - 1, -1), Vector2(2, px * n + 2)), C_FLAME_0)
		if i % core.box_rows == 0:
			draw_rect(Rect2(_origin + Vector2(-1, i * px - 1), Vector2(px * n + 2, 2)), C_FLAME_0)
	if selected.x >= 0:
		var sel := Rect2(_origin + Vector2(selected.y * px, selected.x * px), Vector2(px, px))
		draw_rect(sel.grow(-1), C_FLAME_3, false, 2.0)


func _draw_rune(v: int, state: String, rect: Rect2, alpha: float) -> void:
	if v < 0 or v >= rune_names.size():
		return
	var tex: Texture2D = _tex.get("%s/%s" % [rune_names[v], state])
	if tex:
		draw_texture_rect(tex, rect, false, Color(1, 1, 1, alpha))
	else:
		var font := get_theme_default_font()
		draw_string(font, rect.position + Vector2(0, rect.size.y * 0.7), str(v + 1),
				HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, int(rect.size.y * 0.5), Color(C_FLAME_2, alpha))


## Annotazioni: rune piccole in una griglia 2x2 (4 rune) o 3x2 (6 rune) dentro la casella.
@warning_ignore("integer_division")
func _draw_notes(r: int, c: int, rect: Rect2) -> void:
	var n := core.size
	var per_row := 2 if n <= 4 else 3
	var rows_n := int(ceil(n / float(per_row)))
	var sub := floorf(rect.size.x / float(maxi(per_row, rows_n)) / 8.0) * 8.0   # multipli di 8: mezza tessera
	sub = maxf(sub, 8.0)
	var total := Vector2(per_row * sub, rows_n * sub)
	var start := rect.position + ((rect.size - total) / 2.0).floor()
	for v in n:
		if core.has_note(r, c, v):
			var cell_rect := Rect2(start + Vector2((v % per_row) * sub, (v / per_row) * sub), Vector2(sub, sub))
			var tex: Texture2D = _tex.get("%s/carved" % rune_names[v])
			if tex:
				draw_texture_rect(tex, cell_rect, false, Color(0.75, 0.6, 0.95, 0.9))


@warning_ignore("integer_division")
func _same_group(a: Vector2i, b: Vector2i) -> bool:
	if a.x == b.x or a.y == b.y:
		return true
	return a.x / core.box_rows == b.x / core.box_rows and a.y / core.box_cols == b.y / core.box_cols


# =====================================================================
# INPUT
# =====================================================================
func _gui_input(event: InputEvent) -> void:
	if not _input_enabled or core == null:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var cell := pos_to_cell(event.position)
		if cell.x >= 0:
			accept_event()
			cell_selected.emit(cell.x, cell.y)


func pos_to_cell(pos: Vector2) -> Vector2i:
	var local := pos - _origin
	var c := int(floorf(local.x / _cell_px))
	var r := int(floorf(local.y / _cell_px))
	if r < 0 or c < 0 or r >= core.size or c >= core.size:
		return Vector2i(-1, -1)
	return Vector2i(r, c)


## Centro di una casella in coordinate locali (per i test).
func cell_center(r: int, c: int) -> Vector2:
	return _origin + Vector2((c + 0.5) * _cell_px, (r + 0.5) * _cell_px)


# =====================================================================
# RISPOSTA AI SEGNALI DEL CORE
# =====================================================================
func _on_cell_changed(r: int, c: int, _rune: int) -> void:
	_flash_cell = Vector2i(r, c)
	_flash_alpha = 1.0
	var t := create_tween()
	t.tween_method(_set_flash_alpha, 1.0, 0.0, 0.4)
	_haptic(10)
	queue_redraw()


func _on_notes_changed(_r: int, _c: int) -> void:
	queue_redraw()


func _on_error(r: int, c: int, rune: int, _hp: int) -> void:
	_error_cell = Vector2i(r, c)
	_error_rune = rune
	_error_alpha = 1.0
	var t := create_tween()
	t.tween_interval(0.25)
	t.tween_method(_set_error_alpha, 1.0, 0.0, 0.45)
	_haptic(40)
	queue_redraw()


func _set_flash_alpha(a: float) -> void:
	_flash_alpha = a
	queue_redraw()


func _set_error_alpha(a: float) -> void:
	_error_alpha = a
	queue_redraw()


## Vittoria: le rune si accendono riga per riga, poi reveal_finished.
func play_victory() -> void:
	_input_enabled = false
	selected = Vector2i(-1, -1)
	highlight_rune = -1
	for r in core.size:
		for c in core.size:
			_lit[Vector2i(r, c)] = true
		queue_redraw()
		await get_tree().create_timer(0.09).timeout
	await get_tree().create_timer(0.4).timeout
	reveal_finished.emit()


func _haptic(ms: int) -> void:
	if haptics_enabled and (OS.has_feature("mobile") or OS.has_feature("web_android")):
		Input.vibrate_handheld(ms)
