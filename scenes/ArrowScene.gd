extends PuzzleSceneBase

## Scena delle Cime Aggrovigliate (GDD #07): si tocca una cima per sfilarla nella
## direzione del gancio. Se la traiettoria è bloccata, la cima urta e torna indietro
## (-1 Concentrazione). Quando la griglia è libera, sotto emerge l'oggetto della prova.
## Non c'è l'Annulla: togliere una cima non blocca mai le altre.
##
## Gerarchia aggiunta alla cornice di PuzzleSceneBase:
## Main
## ├── ArrowGridUI           (tabellone, si espande)
## └── ActionRow (HBox)      (contatore, Aiuto, Inchiostro)

var grid: ArrowGridUI

var _count_label: Label
var _hint_button: Button
var _ink_button: Button


## Avviata da sola (F6) mostra la gaffa del Caso #02; CaseScene imposta case_path dopo.
func _init() -> void:
	case_path = "res://data/cases/case_02.json"


func _puzzle_type() -> String:
	return "arrows"


func _kind_label() -> String:
	return "Cime Aggrovigliate %dx%d" % [int(puzzle["grid_size"]["rows"]), int(puzzle["grid_size"]["cols"])]


func _rules_text() -> String:
	return "Tocca una cima per sfilarla verso il gancio. Se qualcosa la blocca, torna indietro."


func _create_core(p: Dictionary) -> Node:
	var c := ArrowCore.new()
	c.setup_from_puzzle(p)
	return c


func _build_board(parent: VBoxContainer) -> void:
	grid = ArrowGridUI.new()
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.custom_minimum_size = Vector2(0, 220)
	grid.line_tapped.connect(func(_i, _ok): save_progress())
	var sprite: String = puzzle.get("reward_clue", {}).get("sprite_path", "")
	if sprite != "" and ResourceLoader.exists(sprite):
		grid.clue_texture = load(sprite)
	parent.add_child(grid)


func _bind_board() -> void:
	core.line_blocked.connect(func(_i, _b, _d, _hp): _refresh_hud())
	core.line_removed.connect(func(_i): _refresh_hud())
	grid.bind_core(core)


func _build_controls(parent: VBoxContainer) -> void:
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 4)
	parent.add_child(actions)
	_count_label = _add_label(actions, "", 12, C_TEXT)
	_count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_count_label.custom_minimum_size.y = 44
	_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var extra := _add_hint_and_ink(actions)
	_hint_button = extra[0]
	_ink_button = extra[1]


func _refresh_controls() -> void:
	if core == null or _count_label == null:
		return
	var left: int = core.remaining()
	_count_label.text = "Cime: %d" % left if left > 0 else "Libera!"
	_hint_button.disabled = core.is_completed
	_ink_button.disabled = core.is_completed


func _on_hint_pressed() -> void:
	if core.is_completed:
		return
	var i: int = core.use_hint()
	if i >= 0:
		grid.flash_line(i, C_FLAME_2, 3)
	save_progress()


func _play_victory() -> void:
	grid.play_victory()
	await grid.reveal_finished
