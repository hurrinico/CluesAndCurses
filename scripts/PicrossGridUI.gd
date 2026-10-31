class_name PicrossGridUI
extends Control

## Vista della griglia Picross (la "View" del pattern MVC).
## NON contiene regole di gioco: legge lo stato da PicrossCore, gli inoltra le mosse
## del giocatore e si aggiorna ESCLUSIVAMENTE tramite i segnali del Core.
##
## Input supportati (mouse e touch: Godot emula il mouse dal touch di default):
##   - Tap            -> azione primaria (Riempi, o 'X' se la modalità è MARK)
##   - Long-press     -> azione secondaria (l'opposto della modalità corrente)
##   - Drag           -> applica la stessa azione a tutte le celle attraversate,
##                       con blocco sull'asse (riga o colonna) come nei Picross classici
##   - Tasto destro   -> azione secondaria immediata (comodo per test su desktop)

signal input_mode_changed(mode: InputMode)
signal reveal_finished          # fine dell'animazione di rivelazione dopo la vittoria

enum InputMode { FILL, MARK }

@export_group("Texture celle (vuote = placeholder generati)")
@export var tex_empty: Texture2D
@export var tex_filled: Texture2D
@export var tex_marked: Texture2D

@export_group("Aspetto")
@export var cell_separation: int = 2
@export var block_size: int = 5                       # tinta alternata ogni N celle (guida visiva)
@export var block_tint: Color = Color(0.86, 0.86, 0.96)
@export var min_cell_px: float = 12.0
@export var max_cell_px: float = 96.0
## Arrotonda la cella a multipli della dimensione delle tessere (16x16): pixel art senza
## pixel irregolari. 0 = nessun arrotondamento. Si applica solo se la cella è >= a questo valore.
@export var snap_cell_to_px: int = 16
@export var max_hint_font_px: int = 28
@export var hint_color: Color = Color(1.0, 0.957, 0.8)          # #fff4cc
@export_range(0.0, 1.0) var hint_done_alpha: float = 0.25
@export var error_color: Color = Color(0.8, 0.227, 0.18)       # #cc3a2e
## Nebbia Arcanica: colore del "?" e tinta delle celle delle linee annebbiate
@export var fog_color: Color = Color(0.627, 0.314, 0.69)       # #a050b0
@export var fog_cell_tint: Color = Color(0.78, 0.68, 0.92)
## Tinta delle celle piene quando il puzzle è risolto (rivelazione dell'immagine)
@export var solved_tint: Color = Color(1.0, 0.878, 0.541)      # #ffe08a

@export_group("Input & Haptics")
@export var long_press_time: float = 0.35
@export var lock_drag_axis: bool = true
@export var haptics_enabled: bool = true
@export var haptic_tap_ms: int = 10

var core: PicrossCore
var input_mode: InputMode = InputMode.FILL

# --- Nodi generati ---
var _center: CenterContainer
var _col_hints_box: HBoxContainer
var _row_hints_box: VBoxContainer
var _cell_grid: GridContainer
var _cells: Array = []              # _cells[r][c] -> TextureRect

# --- Layout ---
var _cell_px: float = 32.0
var _max_row_hints: int = 1
var _max_col_hints: int = 1
var _input_enabled: bool = false

# --- Texture effettive (esportate o placeholder) ---
var _tex_empty: Texture2D
var _tex_filled: Texture2D
var _tex_marked: Texture2D

# --- Stato del gesto in corso ---
var _pressing: bool = false
var _action_started: bool = false
var _drag_clearing: bool = false
var _drag_target: PicrossCore.CellState = PicrossCore.CellState.FILLED
var _start_cell: Vector2i = Vector2i(-1, -1)
var _last_cell: Vector2i = Vector2i(-1, -1)
var _axis: int = -1                 # -1 libero, 0 = bloccato sulla riga, 1 = sulla colonna
var _core_action_open: bool = false # un gesto = una voce di Undo nel Core
var _long_press_timer: Timer


# =====================================================================
# 1. CICLO DI VITA
# =====================================================================
func _ready() -> void:
	_long_press_timer = Timer.new()
	_long_press_timer.one_shot = true
	_long_press_timer.timeout.connect(_on_long_press)
	add_child(_long_press_timer)

	resized.connect(_apply_layout)

	# Placeholder pixel-art se non sono state assegnate texture nell'Inspector
	var bg := Color(0.14, 0.13, 0.18)
	var border := Color(0.28, 0.26, 0.34)
	_tex_empty = tex_empty if tex_empty else _make_placeholder(bg, border, false, Color.BLACK)
	_tex_filled = tex_filled if tex_filled else _make_placeholder(Color(0.86, 0.80, 0.64), Color(0.58, 0.52, 0.38), false, Color.BLACK)
	_tex_marked = tex_marked if tex_marked else _make_placeholder(bg, border, true, Color(0.78, 0.30, 0.28))


## Collega la UI a un PicrossCore GIÀ inizializzato con setup_puzzle() e costruisce la griglia.
func bind_core(new_core: PicrossCore) -> void:
	if core:
		_disconnect_core()
	core = new_core
	core.cell_changed.connect(_on_cell_changed)
	core.error_committed.connect(_on_error_committed)
	core.row_completed.connect(_on_row_completed)
	core.col_completed.connect(_on_col_completed)
	core.row_uncompleted.connect(_on_row_uncompleted)
	core.col_uncompleted.connect(_on_col_uncompleted)
	core.puzzle_solved.connect(_on_puzzle_solved)
	core.fog_cleared.connect(_on_fog_cleared)
	build_grid()


## Da collegare al tasto [Annulla] della HUD.
func undo() -> void:
	if core and _input_enabled:
		_reset_gesture()
		core.undo()


func _disconnect_core() -> void:
	var links := [
		[core.cell_changed, _on_cell_changed],
		[core.error_committed, _on_error_committed],
		[core.row_completed, _on_row_completed],
		[core.col_completed, _on_col_completed],
		[core.row_uncompleted, _on_row_uncompleted],
		[core.col_uncompleted, _on_col_uncompleted],
		[core.puzzle_solved, _on_puzzle_solved],
		[core.fog_cleared, _on_fog_cleared],
	]
	for link in links:
		var sig: Signal = link[0]
		if sig.is_connected(link[1]):
			sig.disconnect(link[1])


# =====================================================================
# 2. COSTRUZIONE DINAMICA DELLA GRIGLIA
# =====================================================================
## Struttura generata:
## CenterContainer
## └── Layout (GridContainer, 2 colonne)
##     ├── Corner (Control vuoto)      ├── ColHints (HBox -> una VBox per colonna)
##     ├── RowHints (VBox -> una HBox per riga)  └── CellGrid (GridContainer di TextureRect)
func build_grid() -> void:
	if core == null or core.rows == 0:
		push_warning("PicrossGridUI: chiama core.setup_puzzle() prima di bind_core().")
		return

	if _center:
		remove_child(_center)
		_center.queue_free()
	_cells.clear()
	_reset_gesture()

	_center = CenterContainer.new()
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center)
	_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var layout := GridContainer.new()
	layout.columns = 2
	layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.add_theme_constant_override("h_separation", 8)
	layout.add_theme_constant_override("v_separation", 8)
	_center.add_child(layout)

	var corner := Control.new()
	corner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.add_child(corner)

	_col_hints_box = HBoxContainer.new()
	_col_hints_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col_hints_box.add_theme_constant_override("separation", cell_separation)
	layout.add_child(_col_hints_box)

	_row_hints_box = VBoxContainer.new()
	_row_hints_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row_hints_box.add_theme_constant_override("separation", cell_separation)
	layout.add_child(_row_hints_box)

	# La griglia è l'UNICO nodo che riceve input: le celle sono solo grafica.
	# Così il drag funziona anche su touch (un Button "catturerebbe" il dito sulla prima cella).
	_cell_grid = GridContainer.new()
	_cell_grid.columns = core.cols
	_cell_grid.mouse_filter = Control.MOUSE_FILTER_STOP
	_cell_grid.add_theme_constant_override("h_separation", cell_separation)
	_cell_grid.add_theme_constant_override("v_separation", cell_separation)
	_cell_grid.gui_input.connect(_on_grid_input)
	layout.add_child(_cell_grid)

	# --- Numeri guida delle colonne (impilati in verticale, allineati in basso) ---
	_max_col_hints = 1
	for c in core.cols:
		var hints := core.get_col_hints(c)
		_max_col_hints = maxi(_max_col_hints, hints.size())
		var col_box := VBoxContainer.new()
		col_box.alignment = BoxContainer.ALIGNMENT_END
		col_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col_box.add_theme_constant_override("separation", 0)
		for n in hints:
			col_box.add_child(_make_hint_label(n))
		_col_hints_box.add_child(col_box)
		if core.is_col_fogged(c):
			_set_line_fog(col_box, true)
		if core.is_col_done(c):   # include le colonne "0" e quelle di un salvataggio
			_set_line_done(col_box, true)

	# --- Numeri guida delle righe (in orizzontale, allineati a destra) ---
	_max_row_hints = 1
	for r in core.rows:
		var hints := core.get_row_hints(r)
		_max_row_hints = maxi(_max_row_hints, hints.size())
		var row_box := HBoxContainer.new()
		row_box.alignment = BoxContainer.ALIGNMENT_END
		row_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row_box.add_theme_constant_override("separation", 6)
		for n in hints:
			row_box.add_child(_make_hint_label(n))
		_row_hints_box.add_child(row_box)
		if core.is_row_fogged(r):
			_set_line_fog(row_box, true)
		if core.is_row_done(r):
			_set_line_done(row_box, true)

	# --- Celle ---
	for r in core.rows:
		var row_arr: Array = []
		for c in core.cols:
			var cell := TextureRect.new()
			cell.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			cell.stretch_mode = TextureRect.STRETCH_SCALE
			cell.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # pixel art nitida
			cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var base := _cell_base(r, c)
			cell.set_meta("base_modulate", base)
			# Le 'X' d'errore (anche da un salvataggio) restano leggermente arrossate
			cell.modulate = base.lerp(error_color, 0.3) if core.is_locked(r, c) else base
			cell.texture = _texture_for(core.player_matrix[r][c])
			_cell_grid.add_child(cell)
			row_arr.append(cell)
		_cells.append(row_arr)

	# Niente blocco a Concentrazione 0: il giocatore continua e la prova risulta "Danneggiata"
	_input_enabled = not core.is_completed
	_apply_layout()


## Calcola la dimensione delle celle per far stare griglia + numeri guida nello schermo.
func _apply_layout() -> void:
	if core == null or _cells.is_empty():
		return
	var sep := float(cell_separation)
	var avail := size - Vector2(16, 16)   # margine esterno + separazione del layout
	# Stima dello spazio dei numeri guida in proporzione alla cella (cifre ~0.6 cella)
	var px_w := (avail.x - core.cols * sep) / (core.cols + _max_row_hints * 0.6)
	var px_h := (avail.y - core.rows * sep) / (core.rows + _max_col_hints * 0.6)
	_cell_px = clampf(floorf(minf(px_w, px_h)), min_cell_px, max_cell_px)
	# Pixel nitidi: multipli della tessera (16) quando la cella è grande; sulle griglie grandi
	# dei telefoni si scende a multipli di mezza tessera (24 px invece di 16: tocco più comodo).
	if snap_cell_to_px > 0 and _cell_px >= snap_cell_to_px * 3:
		_cell_px = floorf(_cell_px / snap_cell_to_px) * snap_cell_to_px
	elif snap_cell_to_px > 0 and _cell_px >= snap_cell_to_px:
		var half := snap_cell_to_px / 2.0
		_cell_px = floorf(_cell_px / half) * half
	var font_px := clampi(int(_cell_px * 0.55), 10, max_hint_font_px)

	for row_arr in _cells:
		for cell in row_arr:
			cell.custom_minimum_size = Vector2(_cell_px, _cell_px)
	for col_box in _col_hints_box.get_children():
		col_box.custom_minimum_size.x = _cell_px
		for lbl in col_box.get_children():
			lbl.add_theme_font_size_override("font_size", font_px)
	for row_box in _row_hints_box.get_children():
		row_box.custom_minimum_size.y = _cell_px
		for lbl in row_box.get_children():
			lbl.add_theme_font_size_override("font_size", font_px)


# =====================================================================
# 3. GESTIONE INPUT (TAP / LONG-PRESS / DRAG)
# =====================================================================
func set_input_mode(mode: InputMode) -> void:
	input_mode = mode
	input_mode_changed.emit(mode)


## Da collegare a un pulsante [Riempi / X] nella HUD.
func toggle_input_mode() -> void:
	set_input_mode(InputMode.MARK if input_mode == InputMode.FILL else InputMode.FILL)


func _primary_target() -> PicrossCore.CellState:
	return PicrossCore.CellState.FILLED if input_mode == InputMode.FILL else PicrossCore.CellState.MARKED_X


func _secondary_target() -> PicrossCore.CellState:
	return PicrossCore.CellState.MARKED_X if input_mode == InputMode.FILL else PicrossCore.CellState.FILLED


func _on_grid_input(event: InputEvent) -> void:
	if not _input_enabled:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT and mb.button_index != MOUSE_BUTTON_RIGHT:
			return
		if mb.pressed:
			_on_press(mb.position, mb.button_index == MOUSE_BUTTON_RIGHT)
		else:
			_on_release()
		_cell_grid.accept_event()
	elif event is InputEventMouseMotion and _pressing:
		_on_drag((event as InputEventMouseMotion).position)
		_cell_grid.accept_event()


func _on_press(pos: Vector2, secondary: bool) -> void:
	var cell := _pos_to_cell(pos, false)
	if cell.x < 0:
		return
	_reset_gesture()
	_pressing = true
	_start_cell = cell
	_last_cell = cell
	if secondary:
		_begin_action(_secondary_target())
	else:
		# Aspettiamo: può diventare un tap (rilascio), un long-press (timer) o un drag (movimento)
		_long_press_timer.start(long_press_time)


func _on_long_press() -> void:
	if _pressing and not _action_started:
		_haptic(25)
		_begin_action(_secondary_target())


func _on_drag(pos: Vector2) -> void:
	var cell := _pos_to_cell(pos, true)
	if lock_drag_axis:
		if _axis == -1 and cell != _start_cell:
			if cell.x == _start_cell.x:
				_axis = 0
			elif cell.y == _start_cell.y:
				_axis = 1
			else:
				_axis = 0 if absi(cell.y - _start_cell.y) >= absi(cell.x - _start_cell.x) else 1
		if _axis == 0:
			cell.x = _start_cell.x
		elif _axis == 1:
			cell.y = _start_cell.y
	if cell == _last_cell:
		return

	_long_press_timer.stop()
	if not _action_started:
		_begin_action(_primary_target())
		if not _pressing:   # errore sulla prima cella: gesto interrotto
			return
	_apply_segment(_last_cell, cell)
	_last_cell = cell


func _on_release() -> void:
	if not _pressing:
		return
	_long_press_timer.stop()
	if not _action_started:
		_begin_action(_primary_target())   # era un tap semplice
	_reset_gesture()


## Decide l'azione dell'intero gesto in base alla PRIMA cella:
## se è già nello stato bersaglio il gesto "cancella", altrimenti "applica".
## Così il drag non alterna pieno/vuoto cella per cella (il Core fa toggle).
func _begin_action(target: PicrossCore.CellState) -> void:
	_action_started = true
	core.begin_action()
	_core_action_open = true
	_drag_target = target
	_drag_clearing = core.player_matrix[_start_cell.x][_start_cell.y] == target
	_apply_to_cell(_start_cell)


## Riempie anche le celle "saltate" quando il dito si muove velocemente.
func _apply_segment(from: Vector2i, to: Vector2i) -> void:
	var steps := maxi(absi(to.x - from.x), absi(to.y - from.y))
	for i in range(1, steps + 1):
		if not _pressing:   # un errore ha interrotto il gesto
			return
		var t := float(i) / steps
		var cur := Vector2i(roundi(lerpf(from.x, to.x, t)), roundi(lerpf(from.y, to.y, t)))
		_apply_to_cell(cur)


func _apply_to_cell(cell: Vector2i) -> void:
	if core.is_locked(cell.x, cell.y):
		return
	var state: int = core.player_matrix[cell.x][cell.y]
	if _drag_clearing:
		if state == _drag_target:
			core.interact_cell(cell.x, cell.y, _drag_target)   # toggle -> EMPTY
	elif state == PicrossCore.CellState.EMPTY:
		core.interact_cell(cell.x, cell.y, _drag_target)
	# Celle in uno stato diverso (es. 'X' durante un drag di riempimento) non vengono toccate


func _reset_gesture() -> void:
	_pressing = false
	_action_started = false
	_axis = -1
	if _long_press_timer:
		_long_press_timer.stop()
	if _core_action_open:
		_core_action_open = false
		if core:
			core.end_action()


## Converte una posizione locale della griglia in Vector2i(riga, colonna).
func _pos_to_cell(pos: Vector2, clamp_inside: bool) -> Vector2i:
	var step := _cell_px + cell_separation
	var r := int(floorf(pos.y / step))
	var c := int(floorf(pos.x / step))
	if clamp_inside:
		return Vector2i(clampi(r, 0, core.rows - 1), clampi(c, 0, core.cols - 1))
	if r < 0 or c < 0 or r >= core.rows or c >= core.cols:
		return Vector2i(-1, -1)
	return Vector2i(r, c)


# =====================================================================
# 4. RISPOSTA AI SEGNALI DEL CORE
# =====================================================================
func _on_cell_changed(r: int, c: int, new_state: int) -> void:
	if _cells.is_empty():
		return
	_cells[r][c].texture = _texture_for(new_state)
	if new_state != PicrossCore.CellState.EMPTY:
		_haptic(haptic_tap_ms)


func _on_error_committed(r: int, c: int, _hp_remaining: int) -> void:
	# La cella è già bloccata dal Core. A Concentrazione 0 si continua a giocare:
	# la HUD ascolta core.concentration_depleted per mostrare lo stato "Danneggiata".
	_reset_gesture()                 # ferma il drag: niente raffica di errori
	_flash_error(_cells[r][c])
	_haptic_error()


func _on_row_completed(r: int) -> void:
	_set_line_done(_row_hints_box.get_child(r), true)


func _on_col_completed(c: int) -> void:
	_set_line_done(_col_hints_box.get_child(c), true)


func _on_row_uncompleted(r: int) -> void:
	_set_line_done(_row_hints_box.get_child(r), false)


func _on_col_uncompleted(c: int) -> void:
	_set_line_done(_col_hints_box.get_child(c), false)


## La nebbia su una linea si dirada: tornano i numeri guida e le celle perdono la tinta viola.
func _on_fog_cleared(is_row: bool, index: int) -> void:
	if _cells.is_empty():
		return
	var box: Control = _row_hints_box.get_child(index) if is_row else _col_hints_box.get_child(index)
	_set_line_fog(box, false)
	box.scale = Vector2(1.3, 1.3)
	box.pivot_offset = box.size / 2
	create_tween().tween_property(box, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK)
	var count := core.cols if is_row else core.rows
	for i in count:
		var r := index if is_row else i
		var c := i if is_row else index
		var cell: TextureRect = _cells[r][c]
		var base := _cell_base(r, c)
		cell.set_meta("base_modulate", base)
		if not core.is_completed:
			cell.modulate = base.lerp(error_color, 0.3) if core.is_locked(r, c) else base
	_haptic(20)


func _on_puzzle_solved() -> void:
	_input_enabled = false
	_reset_gesture()
	_haptic_victory()
	_play_reveal()


## Rivelazione: le celle piene si accendono riga per riga, le 'X' sfumano.
## Al termine emette reveal_finished: la scena mostra l'illustrazione della prova.
func _play_reveal() -> void:
	var tween := create_tween().set_parallel(true)
	for r in core.rows:
		for c in core.cols:
			var cell: TextureRect = _cells[r][c]
			var delay := r * 0.05
			if core.player_matrix[r][c] == PicrossCore.CellState.FILLED:
				tween.tween_property(cell, "modulate", solved_tint, 0.3).set_delay(delay)
			else:
				tween.tween_property(cell, "modulate:a", 0.25, 0.3).set_delay(delay)
	tween.chain().tween_interval(0.3)
	tween.chain().tween_callback(reveal_finished.emit)


# =====================================================================
# 5. UTILITY GRAFICHE
# =====================================================================
func _texture_for(state: int) -> Texture2D:
	match state:
		PicrossCore.CellState.FILLED:
			return _tex_filled
		PicrossCore.CellState.MARKED_X:
			return _tex_marked
		_:
			return _tex_empty


func _make_hint_label(n: int) -> Label:
	var lbl := Label.new()
	lbl.text = str(n)
	lbl.set_meta("n", n)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.add_theme_color_override("font_color", hint_color)
	return lbl


func _cell_base(r: int, c: int) -> Color:
	var base := block_tint if _is_alt_block(r, c) else Color.WHITE
	if core and (core.is_row_fogged(r) or core.is_col_fogged(c)):
		base = base * fog_cell_tint
	return base


## Nebbia: i numeri della linea diventano un solo "?" viola (o tornano visibili).
func _set_line_fog(line_box: Control, fogged: bool) -> void:
	var labels := line_box.get_children()
	for i in labels.size():
		var lbl: Label = labels[i]
		if fogged:
			lbl.visible = i == labels.size() - 1
			lbl.text = "?"
			lbl.add_theme_color_override("font_color", fog_color)
		else:
			lbl.visible = true
			lbl.text = str(lbl.get_meta("n", 0))
			lbl.add_theme_color_override("font_color", hint_color)


## Auto-Dimming dei numeri guida (GDD #03)
func _set_line_done(line_box: Control, done: bool) -> void:
	line_box.modulate.a = hint_done_alpha if done else 1.0


@warning_ignore("integer_division")
func _is_alt_block(r: int, c: int) -> bool:
	if block_size <= 0:
		return false
	return ((r / block_size) + (c / block_size)) % 2 == 1


func _flash_error(cell: TextureRect) -> void:
	var base: Color = cell.get_meta("base_modulate", Color.WHITE)
	cell.modulate = error_color
	# La cella resta leggermente arrossata: distingue le 'X' d'errore da quelle del giocatore
	create_tween().tween_property(cell, "modulate", base.lerp(error_color, 0.3), 0.45)


## Texture 16x16 provvisoria, finché non arrivano gli sprite definitivi.
func _make_placeholder(bg: Color, border: Color, draw_x: bool, x_color: Color) -> ImageTexture:
	var s := 16
	var img := Image.create_empty(s, s, false, Image.FORMAT_RGBA8)
	img.fill(bg)
	for i in s:
		img.set_pixel(i, 0, border)
		img.set_pixel(i, s - 1, border)
		img.set_pixel(0, i, border)
		img.set_pixel(s - 1, i, border)
	if draw_x:
		for i in range(4, s - 4):
			img.set_pixel(i, i, x_color)
			img.set_pixel(s - 1 - i, i, x_color)
	return ImageTexture.create_from_image(img)


# =====================================================================
# 6. HAPTICS (GDD #03: leggero / doppio impulso / crescendo)
# =====================================================================
func _haptic(ms: int) -> void:
	if haptics_enabled and OS.has_feature("mobile"):
		Input.vibrate_handheld(ms)


func _haptic_error() -> void:
	_haptic(40)
	await get_tree().create_timer(0.09).timeout
	_haptic(40)


func _haptic_victory() -> void:
	for ms in [15, 25, 40, 70]:
		_haptic(ms)
		await get_tree().create_timer(0.12).timeout
