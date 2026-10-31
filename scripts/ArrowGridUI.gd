class_name ArrowGridUI
extends Control

## Vista delle Cime Aggrovigliate (la "View" del pattern MVC, GDD #07).
## Disegna con _draw il groviglio di cime sopra il pontile: ogni cima è una corda (o catena)
## che passa per i centri delle sue celle e finisce con un gancio a punta di freccia.
## Sotto le cime si intravede l'oggetto della prova (la gaffa), che emerge del tutto
## quando la griglia è libera.
##
## Animazioni (in coordinate di cella, poi trasformate in pixel):
##   - uscita: la cima scorre come un serpente lungo il proprio percorso e prosegue in linea retta
##   - urto: la cima avanza fino all'ostacolo, rimbalza e torna al suo posto; le due cime lampeggiano
## Input: tap/clic su una cella occupata -> core.try_remove() sulla cima che la occupa.

signal reveal_finished
signal line_tapped(index: int, removed: bool)

@export var haptics_enabled: bool = true
@export var slide_speed: float = 14.0      # celle al secondo
@export var max_cell_px: int = 64

# --- Palette ---
const C_NIGHT_0 := Color("0b0a12")
const C_NIGHT_1 := Color("14121f")
const C_NIGHT_2 := Color("1c1b2e")
const C_NIGHT_3 := Color("262640")
const C_NIGHT_4 := Color("313552")
const C_NIGHT_5 := Color("3f4866")
const C_NIGHT_6 := Color("56607e")
const C_NIGHT_7 := Color("7a83a0")
const C_WOOD_1 := Color("33201a")
const C_WOOD_2 := Color("4a2e21")
const C_WOOD_3 := Color("66412b")
const C_WOOD_4 := Color("85593a")
const C_WOOD_5 := Color("a8774f")
const C_FLAME_0 := Color("c2803a")
const C_FLAME_1 := Color("dba04a")
const C_FLAME_2 := Color("f0c060")
const C_FLAME_3 := Color("ffe08a")
const C_FLAME_4 := Color("fff4cc")
const C_BLOOD := Color("cc3a2e")

## Tre materiali alternati, così cime vicine si distinguono: [corpo, luce, ombra/torsione]
const MATERIALS := [
	[C_WOOD_4, C_WOOD_5, C_WOOD_2],      # canapa
	[C_FLAME_0, C_FLAME_2, C_WOOD_3],    # corda catramata chiara
	[C_NIGHT_6, C_NIGHT_7, C_NIGHT_4],   # catena di ferro
]

var core: ArrowCore
var clue_texture: Texture2D            # l'oggetto sotto il groviglio (facoltativo)

var _cell_px: int = 40
var _origin: Vector2 = Vector2.ZERO
var _offset: Array = []                # scorrimento corrente di ogni linea, in celle
var _alpha: Array = []                 # 0 = linea sparita
var _flash: Array = []                 # 0..1: lampeggio rosso (urto) o dorato (aiuto)
var _flash_color: Array = []
var _animating: Dictionary = {}        # linee in movimento
var _reveal: float = 0.0               # 0..1: quanto si vede l'oggetto sotto
var _input_enabled := true


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	resized.connect(_layout)


func bind_core(new_core: ArrowCore) -> void:
	if core and core.line_removed.is_connected(_on_line_removed):
		core.line_removed.disconnect(_on_line_removed)
		core.line_blocked.disconnect(_on_line_blocked)
	core = new_core
	core.line_removed.connect(_on_line_removed)
	core.line_blocked.connect(_on_line_blocked)
	_offset.clear()
	_alpha.clear()
	_flash.clear()
	_flash_color.clear()
	_animating.clear()
	for i in core.lines.size():
		_offset.append(0.0)
		_alpha.append(0.0 if core.removed[i] else 1.0)
		_flash.append(0.0)
		_flash_color.append(C_BLOOD)
	_reveal = _progress()
	_input_enabled = not core.is_completed
	_layout()


func cell_px() -> int:
	return _cell_px


## Centro di una cella in coordinate locali (per i test e per l'input).
func cell_center(r: int, c: int) -> Vector2:
	return _origin + Vector2((c + 0.5) * _cell_px, (r + 0.5) * _cell_px)


func is_animating() -> bool:
	return not _animating.is_empty()


# =====================================================================
# LAYOUT
# =====================================================================
@warning_ignore("integer_division")
func _layout() -> void:
	if core == null or core.rows == 0:
		return
	var px := mini((int(size.x) - 16) / core.cols, (int(size.y) - 16) / core.rows)
	px = clampi(px, 16, max_cell_px)
	px -= px % 2                                   # pari: i centri cadono su pixel interi
	_cell_px = px
	var board := Vector2(px * core.cols, px * core.rows)
	_origin = ((size - board) / 2.0).floor()
	queue_redraw()


func _progress() -> float:
	if core == null or core.lines.is_empty():
		return 0.0
	return 1.0 - float(core.remaining()) / core.lines.size()


# =====================================================================
# DISEGNO
# =====================================================================
func _draw() -> void:
	if core == null:
		return
	var px := float(_cell_px)
	var board := Rect2(_origin, Vector2(px * core.cols, px * core.rows))
	# il pontile: assi di legno scuro, poi i punti d'ancoraggio delle celle
	draw_rect(board.grow(6), C_NIGHT_0)
	draw_rect(board.grow(4), C_WOOD_1)
	draw_rect(board, C_NIGHT_1)
	for r in core.rows:
		if r % 2 == 1:
			draw_rect(Rect2(_origin + Vector2(0, r * px), Vector2(board.size.x, px)), Color(C_NIGHT_2, 0.6))
	# l'oggetto sotto il groviglio
	if clue_texture:
		var side := minf(board.size.x, board.size.y) * 0.9
		side = floorf(side / clue_texture.get_width()) * clue_texture.get_width()
		var rect := Rect2(board.get_center() - Vector2(side, side) / 2.0, Vector2(side, side))
		var shade := lerpf(0.18, 1.0, _reveal * _reveal)
		draw_texture_rect(clue_texture, Rect2(rect.position.floor(), rect.size), false, Color(shade, shade, shade * 1.05, lerpf(0.35, 1.0, _reveal)))
	for r in core.rows:
		for c in core.cols:
			var p := cell_center(r, c).floor()
			draw_rect(Rect2(p - Vector2(1, 1), Vector2(2, 2)), C_NIGHT_4)
	# le cime: prima le ferme, poi quelle in movimento (sopra)
	var order: Array = []
	for i in core.lines.size():
		if not _animating.has(i):
			order.append(i)
	order.append_array(_animating.keys())
	for i in order:
		if _alpha[i] > 0.0:
			_draw_line(i)


## Percorso esteso della linea in coordinate di cella (centri): le sue celle, poi la
## traiettoria dritta oltre il bordo, abbastanza lunga da far uscire tutta la cima.
func _extended_path(i: int) -> Array:
	var pts: Array = []
	for cell in core.lines[i]:
		pts.append(Vector2(cell.y + 0.5, cell.x + 0.5))
	var d: Vector2i = core.head_dir(i)
	var step := Vector2(d.y, d.x)
	var extra: int = core.lines[i].size() + maxi(core.rows, core.cols) + 2
	var last: Vector2 = pts[-1]
	for k in range(1, extra + 1):
		pts.append(last + step * k)
	return pts


## Punto alla distanza t (in celle) lungo il percorso: tutti i tratti sono lunghi 1 cella.
func _point_at(path: Array, t: float) -> Vector2:
	t = clampf(t, 0.0, path.size() - 1.0)
	var k := mini(int(floorf(t)), path.size() - 2)
	return (path[k] as Vector2).lerp(path[k + 1], t - k)


func _to_px(p: Vector2) -> Vector2:
	return (_origin + p * _cell_px).floor()


@warning_ignore("integer_division")
func _draw_line(i: int) -> void:
	var path := _extended_path(i)
	var length: float = core.lines[i].size() - 1.0
	var t0: float = _offset[i]
	var t1 := t0 + length
	# punti del tratto visibile: inizio, vertici interi in mezzo, fine
	var pts: Array = [_to_px(_point_at(path, t0))]
	for k in range(int(floorf(t0)) + 1, int(ceilf(t1))):
		pts.append(_to_px(path[k]))
	pts.append(_to_px(_point_at(path, t1)))

	var mat: Array = MATERIALS[i % MATERIALS.size()]
	var body: Color = mat[0]
	var light: Color = mat[1]
	var dark: Color = mat[2]
	if _flash[i] > 0.0:
		body = body.lerp(_flash_color[i], _flash[i])
		light = light.lerp(_flash_color[i].lightened(0.3), _flash[i])
	var a: float = _alpha[i]
	var w := maxi(4, int(_cell_px * 0.24))
	w += w % 2
	var hw := w / 2
	# 1) contorno scuro, 2) corpo, 3) luce sul lato alto/sinistro, 4) torsioni
	for pass_i in 3:
		for k in pts.size() - 1:
			var p: Vector2 = pts[k]
			var q: Vector2 = pts[k + 1]
			var rect := Rect2(Vector2(minf(p.x, q.x), minf(p.y, q.y)), Vector2(absf(q.x - p.x), absf(q.y - p.y)))
			match pass_i:
				0:
					draw_rect(rect.grow(hw + 1), Color(C_NIGHT_0, a))
				1:
					draw_rect(rect.grow(hw), Color(body, a))
				2:
					var horizontal := absf(q.x - p.x) >= absf(q.y - p.y)
					if horizontal:
						draw_rect(Rect2(rect.position + Vector2(-hw, -hw), Vector2(rect.size.x + w, 1)), Color(light, a))
						var x := rect.position.x - hw + 2
						while x < rect.end.x + hw - 2:
							draw_rect(Rect2(Vector2(x, rect.position.y - hw + 1), Vector2(1, hw)), Color(dark, a))
							draw_rect(Rect2(Vector2(x + 1, rect.position.y), Vector2(1, hw)), Color(dark, a))
							x += 4
					else:
						draw_rect(Rect2(rect.position + Vector2(-hw, -hw), Vector2(1, rect.size.y + w)), Color(light, a))
						var y := rect.position.y - hw + 2
						while y < rect.end.y + hw - 2:
							draw_rect(Rect2(Vector2(rect.position.x - hw + 1, y), Vector2(hw, 1)), Color(dark, a))
							draw_rect(Rect2(Vector2(rect.position.x, y + 1), Vector2(hw, 1)), Color(dark, a))
							y += 4
	# coda: un nodo sulla prima cella
	var tail: Vector2 = pts[0]
	draw_rect(Rect2(tail - Vector2(hw + 1, hw + 1), Vector2(w + 2, w + 2)), Color(C_NIGHT_0, a))
	draw_rect(Rect2(tail - Vector2(hw, hw), Vector2(w, w)), Color(dark, a))
	# gancio: punta di freccia in ottone
	var head: Vector2 = pts[-1]
	var d: Vector2i = core.head_dir(i)
	var dir := Vector2(d.y, d.x)
	var side := Vector2(-dir.y, dir.x)
	var s := float(maxi(6, int(_cell_px * 0.3)))
	var tip := head + dir * s
	var base_l := head - dir * (s * 0.2) + side * s * 0.8
	var base_r := head - dir * (s * 0.2) - side * s * 0.8
	var outline := PackedVector2Array([tip + dir * 1.5, base_l + side * 1.5 - dir, base_r - side * 1.5 - dir])
	draw_colored_polygon(outline, Color(C_NIGHT_0, a))
	var head_col := C_FLAME_2.lerp(_flash_color[i], _flash[i]) if _flash[i] > 0.0 else C_FLAME_2
	draw_colored_polygon(PackedVector2Array([tip, base_l, base_r]), Color(head_col, a))
	draw_line(tip, base_l, Color(C_FLAME_4, a))


# =====================================================================
# INPUT
# =====================================================================
func _gui_input(event: InputEvent) -> void:
	if not _input_enabled or core == null:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var cell := pos_to_cell(event.position)
		if cell.x < 0:
			return
		accept_event()
		var index := core.line_at(cell)
		if index < 0 or _animating.has(index):
			return
		var ok := core.try_remove(index)
		line_tapped.emit(index, ok)


func pos_to_cell(pos: Vector2) -> Vector2i:
	var local := pos - _origin
	var c := int(floorf(local.x / _cell_px))
	var r := int(floorf(local.y / _cell_px))
	if r < 0 or c < 0 or r >= core.rows or c >= core.cols:
		return Vector2i(-1, -1)
	return Vector2i(r, c)


# =====================================================================
# ANIMAZIONI
# =====================================================================
func _on_line_removed(i: int) -> void:
	_animating[i] = true
	var travel: float = core.lines[i].size() + core.ray(i).size() + 1.5
	var dur := clampf(travel / slide_speed, 0.25, 0.9)
	var t := create_tween()
	t.tween_method(_set_offset.bind(i), 0.0, travel, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	t.parallel().tween_method(_set_alpha.bind(i), 1.0, 0.0, dur * 0.35).set_delay(dur * 0.65)
	t.parallel().tween_method(_set_reveal, _reveal, _progress(), dur)
	t.tween_callback(_end_anim.bind(i))
	_haptic(12)


func _on_line_blocked(i: int, blocker: int, distance: int, _hp: int) -> void:
	_animating[i] = true
	var reach := distance + 0.3     # la punta arriva a toccare l'ostacolo
	var t := create_tween()
	t.tween_method(_set_offset.bind(i), 0.0, reach, maxf(0.08, reach / slide_speed)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	t.tween_method(_set_offset.bind(i), reach, 0.0, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_callback(_end_anim.bind(i))
	flash_line(i, C_BLOOD)
	flash_line(blocker, C_BLOOD)
	_haptic(40)


## Lampeggio di una cima: rosso per l'urto, dorato per l'aiuto.
func flash_line(i: int, color: Color, pulses: int = 1) -> void:
	if i < 0 or i >= _flash.size():
		return
	_flash_color[i] = color
	var t := create_tween()
	for k in pulses:
		t.tween_method(_set_flash.bind(i), 0.0, 1.0, 0.12)
		t.tween_method(_set_flash.bind(i), 1.0, 0.0, 0.35)


func _set_offset(v: float, i: int) -> void:
	_offset[i] = v
	queue_redraw()


func _set_alpha(v: float, i: int) -> void:
	_alpha[i] = v
	queue_redraw()


func _set_flash(v: float, i: int) -> void:
	_flash[i] = v
	queue_redraw()


func _end_anim(i: int) -> void:
	_animating.erase(i)
	if core.removed[i]:
		_alpha[i] = 0.0
	_offset[i] = 0.0
	queue_redraw()


## Vittoria: l'oggetto emerge del tutto, poi reveal_finished.
func play_victory() -> void:
	_input_enabled = false
	while is_animating():
		await get_tree().process_frame
	var t := create_tween()
	t.tween_method(_set_reveal, _reveal, 1.0, 0.6)
	t.tween_interval(0.5)
	t.tween_callback(reveal_finished.emit)
	_haptic(60)


func _set_reveal(v: float) -> void:
	_reveal = v
	queue_redraw()


func _haptic(ms: int) -> void:
	if haptics_enabled and (OS.has_feature("mobile") or OS.has_feature("web_android")):
		Input.vibrate_handheld(ms)
