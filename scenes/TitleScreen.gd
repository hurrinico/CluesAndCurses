extends Control

## Schermata iniziale di Clues & Curses.
## Sequenza: nero -> lo sfondo emerge -> il logo appare in dissolvenza (con un breve
## bagliore viola) -> compare "Tocca per iniziare" che pulsa -> al tocco dissolvenza
## al nero e passaggio alla scena di gioco.
## Un tocco durante l'animazione la salta (mostra subito tutto).
##
## Gerarchia costruita in _build():
## TitleScreen (Control, questo script)
## ├── Background (TextureRect, title_bg.png 360x640)
## ├── Rain (Control con _draw: pioggia animata in pixel)
## ├── Glow (TextureRect: alone radiale viola additivo dietro il logo)
## ├── Logo (TextureRect, logo_cc.png, x1 nella risoluzione logica)
## ├── TapLabel (Label "Tocca per iniziare")
## └── Fade (ColorRect nero a schermo intero, per entrate/uscite)

@export var next_scene: String = "res://scenes/CaseSelect.tscn"
@export var logo_delay: float = 0.9        # secondi di solo sfondo prima del logo
@export var logo_fade_time: float = 2.4
@export var rain_drops: int = 90

const BG_PATH := "res://assets/title/title_bg.png"
const LOGO_PATH := "res://assets/title/logo_cc.png"
const FONT_PATH := "res://assets/fonts/PixelifySans-Regular.ttf"

const C_NIGHT_0 := Color("0b0a12")
const C_RAIN := Color("56607e")
const C_RAIN_LIGHT := Color("7a83a0")
const C_TEXT := Color("fff4cc")
const C_ARCANE := Color("a050b0")

var _bg: TextureRect
var _rain: Control
var _glow: TextureRect
var _logo: TextureRect
var _tap: Label
var _fade: ColorRect

var _drops: Array = []            # [x, y, velocità, lunghezza, chiaro?]
var _intro_tween: Tween
var _pulse_tween: Tween
var _ready_to_start := false
var _leaving := false


func _ready() -> void:
	_build()
	_init_rain()
	_play_intro()


# =====================================================================
# COSTRUZIONE
# =====================================================================
func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var base := ColorRect.new()
	base.color = C_NIGHT_0
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE   # i tocchi devono arrivare a TitleScreen
	add_child(base)
	base.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Sfondo: copre lo schermo mantenendo le proporzioni, ancorato in basso
	# (su telefoni più lunghi di 9:16 si allarga il cielo, non si tagliano i tetti)
	_bg = TextureRect.new()
	_bg.texture = load(BG_PATH)
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_rain = Control.new()
	_rain.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rain.draw.connect(_draw_rain)
	add_child(_rain)
	_rain.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var logo_tex: Texture2D = load(LOGO_PATH)
	var logo_size := logo_tex.get_size()

	# Bagliore: rettangolo viola in blend additivo che pulsa una volta all'apparire del logo
	# Bagliore morbido: gradiente radiale viola -> trasparente (niente rettangolo dai bordi netti)
	var grad := Gradient.new()
	grad.set_color(0, Color(C_ARCANE, 1.0))
	grad.set_color(1, Color(C_ARCANE, 0.0))
	var gtex := GradientTexture2D.new()
	gtex.gradient = grad
	gtex.fill = GradientTexture2D.FILL_RADIAL
	gtex.fill_from = Vector2(0.5, 0.5)
	gtex.fill_to = Vector2(0.5, 0.0)
	gtex.width = 128
	gtex.height = 64
	_glow = TextureRect.new()
	_glow.texture = gtex
	_glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_glow.stretch_mode = TextureRect.STRETCH_SCALE
	_glow.modulate.a = 0.0
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_glow.material = mat
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_glow)

	_logo = TextureRect.new()
	_logo.texture = logo_tex
	_logo.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_logo.stretch_mode = TextureRect.STRETCH_KEEP
	_logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_logo.modulate.a = 0.0
	add_child(_logo)
	# Centrato in orizzontale, nella fascia di cielo libera (circa 17% dall'alto)
	_logo.anchor_left = 0.5
	_logo.anchor_right = 0.5
	_logo.anchor_top = 0.17
	_logo.anchor_bottom = 0.17
	_logo.offset_left = -logo_size.x / 2
	_logo.offset_right = logo_size.x / 2
	_logo.offset_top = 0
	_logo.offset_bottom = logo_size.y

	_glow.anchor_left = 0.5
	_glow.anchor_right = 0.5
	_glow.anchor_top = 0.17
	_glow.anchor_bottom = 0.17
	_glow.offset_left = -logo_size.x / 2 - 40
	_glow.offset_right = logo_size.x / 2 + 40
	_glow.offset_top = -30
	_glow.offset_bottom = 80

	_tap = Label.new()
	_tap.text = "Tocca per iniziare"
	_tap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tap.add_theme_font_override("font", load(FONT_PATH))
	_tap.add_theme_font_size_override("font_size", 16)
	_tap.add_theme_color_override("font_color", C_TEXT)
	_tap.add_theme_color_override("font_outline_color", C_NIGHT_0)
	_tap.add_theme_constant_override("outline_size", 4)
	_tap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tap.modulate.a = 0.0
	add_child(_tap)
	_tap.anchor_left = 0.0
	_tap.anchor_right = 1.0
	_tap.anchor_top = 0.86
	_tap.anchor_bottom = 0.86
	_tap.offset_bottom = 20

	_fade = ColorRect.new()
	_fade.color = C_NIGHT_0
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


# =====================================================================
# SEQUENZA DI APERTURA
# =====================================================================
func _play_intro() -> void:
	_intro_tween = create_tween()
	# 1) dal nero emerge la città
	_intro_tween.tween_property(_fade, "color:a", 0.0, 1.2).set_trans(Tween.TRANS_SINE)
	_intro_tween.tween_interval(logo_delay)
	# 2) il logo appare in dissolvenza, con un lampo viola che si spegne
	_intro_tween.tween_property(_logo, "modulate:a", 1.0, logo_fade_time) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_intro_tween.parallel().tween_property(_glow, "modulate:a", 0.55, logo_fade_time * 0.6) \
			.set_trans(Tween.TRANS_SINE)
	_intro_tween.tween_property(_glow, "modulate:a", 0.12, 1.2).set_trans(Tween.TRANS_SINE)
	# 3) "Tocca per iniziare"
	_intro_tween.tween_callback(_show_tap_prompt)


func _show_tap_prompt() -> void:
	_ready_to_start = true
	_tap.modulate.a = 0.0
	_pulse_tween = create_tween().set_loops()
	_pulse_tween.tween_property(_tap, "modulate:a", 1.0, 0.9).set_trans(Tween.TRANS_SINE)
	_pulse_tween.tween_property(_tap, "modulate:a", 0.25, 0.9).set_trans(Tween.TRANS_SINE)


## Salta l'animazione: tutto visibile subito.
func skip_intro() -> void:
	if _ready_to_start:
		return
	if _intro_tween:
		_intro_tween.kill()
	_fade.color.a = 0.0
	_logo.modulate.a = 1.0
	_glow.modulate.a = 0.12
	_show_tap_prompt()


func start_game() -> void:
	if _leaving:
		return
	_leaving = true
	if _pulse_tween:
		_pulse_tween.kill()
	var t := create_tween()
	t.tween_property(_tap, "modulate:a", 0.0, 0.2)
	t.tween_property(_fade, "color:a", 1.0, 0.8).set_trans(Tween.TRANS_SINE)
	t.tween_callback(func(): get_tree().change_scene_to_file(next_scene))


func _gui_input(event: InputEvent) -> void:
	var pressed: bool = (event is InputEventMouseButton and event.pressed) \
			or (event is InputEventScreenTouch and event.pressed)
	if not pressed:
		return
	accept_event()
	if _ready_to_start:
		start_game()
	else:
		skip_intro()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_pressed() and not event.is_echo():
		if _ready_to_start:
			start_game()
		else:
			skip_intro()


# =====================================================================
# PIOGGIA (pixel art: segmenti diagonali di 1 px, nessun anti-aliasing)
# =====================================================================
func _init_rain() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for i in rain_drops:
		_drops.append([rng.randf() * 400.0, rng.randf() * 700.0,
				rng.randf_range(260.0, 420.0), rng.randi_range(4, 9), rng.randf() < 0.25])


func _process(delta: float) -> void:
	var s := size
	for d in _drops:
		d[1] += d[2] * delta
		d[0] -= d[2] * 0.25 * delta
		if d[1] > s.y + 10:
			d[1] = -10.0
			d[0] = randf() * (s.x + 60.0)
	_rain.queue_redraw()


func _draw_rain() -> void:
	for d in _drops:
		var x: float = roundf(d[0])
		var y: float = roundf(d[1])
		var col: Color = C_RAIN_LIGHT if d[4] else C_RAIN
		col.a = 0.55
		var n: int = d[3]
		# diagonale a scaletta: 1 px a sinistra ogni 4 px in giù
		for i in n:
			_rain.draw_rect(Rect2(x - floorf(i / 4.0), y + i, 1, 1), col)
