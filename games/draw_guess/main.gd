extends Control

## 你画我猜的单机热座界面。
##
## 目前是「一台手机传着玩」的完整可玩形态：
## 画手拿着手机作画，其他人喊答案，画手点对应玩家的名字记分；
## 也可以用下方的输入框代某位玩家打字猜词。
##
## 联网接入时要改的只有两处接线，界面逻辑一行都不用动：
##   1. board.stroke_chunk  -> 交给房间层广播（现在是直接喂给本机游戏逻辑）
##   2. 房间层收到的 stroke_forwarded -> 分发给**远端**的 DrawBoard
## 注意本机画手的笔迹已经本地渲染过了，不要再 apply 一次，否则会重影。

const PLAYER_LIMIT := 8

## 界面配色：整体走浅色底 + 黑字。
## Godot 默认主题是深色的（浅色文字），把浅色文字压在浅色面板上根本读不出来，
## 而且只改 font_color 不够——hover / pressed / disabled 会各自回落到默认主题的浅色。
const INK := Color(0.10, 0.11, 0.13)
const INK_DIM := Color(0.44, 0.47, 0.52)
const INK_ACCENT := Color(0.09, 0.45, 0.20)
const BACKDROP := Color(0.90, 0.92, 0.96)
const SURFACE := Color(1.0, 1.0, 1.0)
const SURFACE_ALT := Color(0.93, 0.95, 0.99)
const SURFACE_PRESSED := Color(0.78, 0.85, 0.97)
const SURFACE_DISABLED := Color(0.88, 0.89, 0.92)
const FOCUS_RING := Color(0.25, 0.52, 0.95)

var _game: DrawGuessGame
var _board: DrawBoard
var _awaiting_pass := false
var _last_phase := -1
var _guesser_buttons := {}

# 界面引用
var _play_area: VBoxContainer
var _setup_panel: PanelContainer
var _pass_panel: PanelContainer
var _choose_panel: PanelContainer
var _result_panel: PanelContainer
var _final_panel: PanelContainer

var _round_label: Label
var _timer_label: Label
var _score_label: Label
var _hint_label: Label
var _word_label: Label
var _choose_box: HBoxContainer
var _color_grid: GridContainer
var _guesser_grid: GridContainer
var _guess_target: OptionButton
var _guess_input: LineEdit
var _feedback_label: Label

var _player_count: OptionButton
var _rounds_input: OptionButton
var _seconds_input: OptionButton
var _difficulty_input: OptionButton

var _pass_label: Label
var _result_title: Label
var _result_rows: VBoxContainer
var _final_rows: VBoxContainer


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	_show_setup()


func _process(delta: float) -> void:
	if _game == null:
		return
	_game.tick(delta)
	_update_live()


# ------------------------------------------------------------------ 界面搭建

func _build() -> void:
	theme = _make_light_theme()

	# 铺一层浅色底。默认的清除色是深灰，黑字压上去同样看不清。
	var backdrop := ColorRect.new()
	backdrop.color = BACKDROP
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 36)
	margin.add_theme_constant_override("margin_right", 36)
	margin.add_theme_constant_override("margin_top", 36)
	margin.add_theme_constant_override("margin_bottom", 36)
	add_child(margin)

	_play_area = VBoxContainer.new()
	_play_area.add_theme_constant_override("separation", 10)
	margin.add_child(_play_area)

	_play_area.add_child(_build_top_bar())
	_play_area.add_child(_build_board())
	_play_area.add_child(_build_hint_bar())
	_play_area.add_child(_build_toolbar())
	_play_area.add_child(_build_guesser_panel())
	_play_area.add_child(_build_guess_row())

	_build_overlays()


func _build_top_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 18)

	_round_label = _label("", 30)
	_timer_label = _label("", 46)
	_score_label = _label("", 26)
	_score_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	bar.add_child(_round_label)
	bar.add_child(_timer_label)
	bar.add_child(_score_label)
	return bar


func _build_board() -> Control:
	# 画板必须保持固定宽高比，否则不同机型上同一份量化坐标会被拉伸成不同的画。
	var holder := AspectRatioContainer.new()
	holder.ratio = 4.0 / 3.0
	holder.stretch_mode = AspectRatioContainer.STRETCH_FIT
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_board = DrawBoard.new()
	_board.background_color = Color(0.99, 0.99, 1.0)
	_board.stroke_chunk.connect(_on_local_stroke)
	holder.add_child(_board)
	return holder


func _build_hint_bar() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	_hint_label = _label("", 30)
	_word_label = _label("", 34)
	_word_label.add_theme_color_override("font_color", INK_ACCENT)
	box.add_child(_hint_label)
	box.add_child(_word_label)
	return box


func _build_toolbar() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	_color_grid = GridContainer.new()
	_color_grid.columns = 8
	_color_grid.add_theme_constant_override("h_separation", 6)
	_color_grid.add_theme_constant_override("v_separation", 6)
	row.add_child(_color_grid)

	var tools := VBoxContainer.new()
	tools.add_theme_constant_override("separation", 4)
	for i in DrawBoard.WIDTH_LEVELS:
		var level := i
		var b := _button(tr("粗细 %d") % (i + 1), 22)
		b.pressed.connect(func(): _board.set_width_level(level))
		tools.add_child(b)
	row.add_child(tools)

	var actions := VBoxContainer.new()
	actions.add_theme_constant_override("separation", 4)
	var eraser := _button(tr("橡皮"), 22)
	eraser.pressed.connect(func(): _board.set_tool(DrawBoard.Tool.ERASER))
	actions.add_child(eraser)
	var undo := _button(tr("撤销"), 22)
	undo.pressed.connect(func(): _board.undo_last_stroke())
	actions.add_child(undo)
	var clear := _button(tr("清空"), 22)
	clear.pressed.connect(_on_clear_pressed)
	actions.add_child(clear)
	row.add_child(actions)

	_rebuild_palette()
	return row


func _rebuild_palette() -> void:
	_clear(_color_grid)
	for i in DrawPalette.COLORS.size():
		var index := i
		var color: Color = DrawPalette.COLORS[i]
		var b := Button.new()
		b.custom_minimum_size = Vector2(52, 52)
		# 千万不要设 flat = true：那会让 Button 不画 normal 样式框，
		# 而色块正是靠 normal 样式框上色的，结果就是整整一排透明方块。
		var normal := StyleBoxFlat.new()
		normal.bg_color = color
		normal.set_corner_radius_all(8)
		if index == _board.get_color_index():
			normal.border_width_top = 4
			normal.border_width_bottom = 4
			normal.border_width_left = 4
			normal.border_width_right = 4
			normal.border_color = Color(1, 1, 1)
		var hover := normal.duplicate()
		hover.border_width_top = 4
		hover.border_width_bottom = 4
		hover.border_width_left = 4
		hover.border_width_right = 4
		hover.border_color = Color(0.1, 0.1, 0.1, 0.6)
		b.add_theme_stylebox_override("normal", normal)
		b.add_theme_stylebox_override("hover", hover)
		b.add_theme_stylebox_override("pressed", hover)
		b.pressed.connect(func():
			_board.set_color_index(index)
			_rebuild_palette())
		_color_grid.add_child(b)


func _build_guesser_panel() -> Control:
	_guesser_grid = GridContainer.new()
	_guesser_grid.columns = 3
	_guesser_grid.add_theme_constant_override("h_separation", 8)
	_guesser_grid.add_theme_constant_override("v_separation", 8)
	return _guesser_grid


func _build_guess_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	_guess_target = OptionButton.new()
	_guess_target.custom_minimum_size = Vector2(180, 0)
	row.add_child(_guess_target)

	_guess_input = LineEdit.new()
	_guess_input.placeholder_text = tr("输入猜测")
	_guess_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_guess_input.text_submitted.connect(func(_t): _submit_guess())
	row.add_child(_guess_input)

	var submit := _button(tr("提交"), 24)
	submit.pressed.connect(_submit_guess)
	row.add_child(submit)

	_feedback_label = _label("", 24)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.add_child(row)
	box.add_child(_feedback_label)
	return box


func _build_overlays() -> void:
	_setup_panel = _panel()
	_setup_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_setup_panel)
	_build_setup_panel()

	_pass_panel = _panel()
	_pass_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_pass_panel)
	var pass_box := VBoxContainer.new()
	pass_box.alignment = BoxContainer.ALIGNMENT_CENTER
	pass_box.add_theme_constant_override("separation", 24)
	_pass_label = _label("", 40)
	_pass_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pass_box.add_child(_pass_label)
	var ready := _button(tr("我准备好了"), 34)
	ready.pressed.connect(func():
		_awaiting_pass = false
		_refresh())
	pass_box.add_child(ready)
	_pass_panel.add_child(pass_box)

	_choose_panel = _panel()
	_choose_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_choose_panel)
	var choose_box := VBoxContainer.new()
	choose_box.alignment = BoxContainer.ALIGNMENT_CENTER
	choose_box.add_theme_constant_override("separation", 24)
	choose_box.add_child(_label(tr("选一个词开始画"), 36))
	_choose_box = HBoxContainer.new()
	_choose_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_choose_box.add_theme_constant_override("separation", 16)
	choose_box.add_child(_choose_box)
	_choose_panel.add_child(choose_box)

	_result_panel = _panel()
	_result_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_result_panel)
	var result_box := VBoxContainer.new()
	result_box.alignment = BoxContainer.ALIGNMENT_CENTER
	result_box.add_theme_constant_override("separation", 20)
	_result_title = _label("", 44)
	_result_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_box.add_child(_result_title)
	_result_rows = VBoxContainer.new()
	_result_rows.add_theme_constant_override("separation", 6)
	result_box.add_child(_result_rows)
	var next := _button(tr("继续"), 30)
	next.pressed.connect(func(): _game.advance_now())
	result_box.add_child(next)
	_result_panel.add_child(result_box)

	_final_panel = _panel()
	_final_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_final_panel)
	var final_box := VBoxContainer.new()
	final_box.alignment = BoxContainer.ALIGNMENT_CENTER
	final_box.add_theme_constant_override("separation", 20)
	final_box.add_child(_label(tr("最终排名"), 44))
	_final_rows = VBoxContainer.new()
	_final_rows.add_theme_constant_override("separation", 6)
	final_box.add_child(_final_rows)
	var again := _button(tr("再来一局"), 30)
	again.pressed.connect(_show_setup)
	final_box.add_child(again)
	_final_panel.add_child(final_box)


func _build_setup_panel() -> void:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 18)

	box.add_child(_label(tr("你画我猜"), 52))
	box.add_child(_label(tr("同一台手机传着玩"), 26))

	box.add_child(_label(tr("玩家人数"), 26))
	_player_count = OptionButton.new()
	for n in range(3, PLAYER_LIMIT + 1):
		_player_count.add_item(tr("%d 人") % n, n)
	_player_count.select(1)
	box.add_child(_player_count)

	box.add_child(_label(tr("回合数"), 26))
	# 用下拉框而不是 SpinBox：手机上那两个小箭头根本点不准，
	# 而且 SpinBox 的箭头图标来自默认深色主题，在浅色底上几乎看不见。
	_rounds_input = OptionButton.new()
	for n in [1, 2, 3, 4, 5, 6, 8, 10]:
		_rounds_input.add_item(tr("%d 回合") % n, n)
	_rounds_input.select(2)
	_rounds_input.custom_minimum_size = Vector2(0, 64)
	box.add_child(_rounds_input)

	box.add_child(_label(tr("每回合时长（秒）"), 26))
	_seconds_input = OptionButton.new()
	for s in [40, 60, 80, 100, 120, 150]:
		_seconds_input.add_item(tr("%d 秒") % s, s)
	_seconds_input.select(2)
	_seconds_input.custom_minimum_size = Vector2(0, 64)
	box.add_child(_seconds_input)

	box.add_child(_label(tr("词库难度"), 26))
	_difficulty_input = OptionButton.new()
	for d in [1, 2, 3]:
		_difficulty_input.add_item(tr(WordBank.DIFFICULTY_NAMES[d]), d)
	_difficulty_input.select(1)
	box.add_child(_difficulty_input)

	var start := _button(tr("开始游戏"), 36)
	start.pressed.connect(_start_game)
	box.add_child(start)

	_setup_panel.add_child(box)


# ------------------------------------------------------------------ 流程

func _show_setup() -> void:
	if _game != null:
		_game.free()
		_game = null
	_board.clear_canvas()
	_awaiting_pass = false
	_last_phase = -1
	_play_area.visible = false
	_result_panel.visible = false
	_final_panel.visible = false
	_choose_panel.visible = false
	_pass_panel.visible = false
	_setup_panel.visible = true


func _start_game() -> void:
	if _game != null:
		_game.free()

	_game = DrawGuessGame.new()
	add_child(_game)
	_game.phase_changed.connect(_on_phase_changed)
	_game.round_started.connect(_on_round_started)
	_game.candidates_offered.connect(_on_candidates)
	_game.guess_evaluated.connect(_on_guess_evaluated)
	_game.someone_guessed.connect(_on_someone_guessed)
	_game.round_settled.connect(_on_round_settled)
	_game.game_finished.connect(_on_game_finished)

	var count := _player_count.get_selected_id()
	var players: Array = []
	for i in count:
		players.append({"peer_id": 100 + i, "name": tr("玩家%d") % (i + 1), "avatar": i})

	_game.setup(players, {
		"rounds": _rounds_input.get_selected_id(),
		"round_seconds": _seconds_input.get_selected_id(),
		"difficulty": _difficulty_input.get_selected_id(),
		"hints": true,
	})

	_setup_panel.visible = false
	_play_area.visible = true
	_rebuild_guesser_panel()
	_rebuild_palette()
	_board.set_color_index(0)
	_board.set_width_level(1)
	_board.clear_canvas()
	_game.start_round()
	_refresh()


func _on_round_started(_index: int) -> void:
	_awaiting_pass = true
	_board.clear_canvas()
	_rebuild_guesser_panel()
	_refresh()


func _on_phase_changed(phase: int, _seconds: float) -> void:
	if phase != _last_phase:
		_last_phase = phase
		_refresh()


func _on_candidates(candidates: Array) -> void:
	for child in _choose_box.get_children():
		child.queue_free()
	for i in candidates.size():
		var index := i
		var entry: Dictionary = candidates[i]
		var b := _button(String(entry["word"]), 30)
		b.pressed.connect(func():
			_game.on_player_input(_local(), DrawGuessMessages.encode_pick_word(index)))
		_choose_box.add_child(b)
	_refresh()


func _on_guess_evaluated(peer_id: int, text: String, correct: bool, near: bool) -> void:
	var name := _name_of(peer_id)
	if correct:
		_feedback_label.text = tr("%s 猜对了！") % name
	else:
		_feedback_label.text = tr("%s：%s —— %s") % [name, text, tr("很接近了") if near else tr("不对")]


func _on_someone_guessed(_peer_id: int, _remaining: float) -> void:
	_rebuild_guesser_panel()


func _on_round_settled(word: String, rows: Array) -> void:
	_result_title.text = tr("答案是「%s」") % word
	_clear(_result_rows)
	if rows.is_empty():
		_result_rows.add_child(_label(tr("没有人猜对"), 28))
	else:
		for r in rows:
			_result_rows.add_child(_label(
				tr("%s  +%d") % [_name_of(int(r["peer_id"])), int(r["points"])], 28))
	_result_rows.add_child(_label(tr("总分：%s") % _score_text(), 26))


func _on_game_finished() -> void:
	_clear(_final_rows)
	var rank := 1
	for r in _game.get_results():
		_final_rows.add_child(_label(
			tr("%d. %s   %d 分") % [rank, _name_of(int(r["peer_id"])), int(r["score"])], 32))
		rank += 1


# ------------------------------------------------------------------ 刷新

func _refresh() -> void:
	if _game == null:
		return
	var phase := _game.get_phase()
	_play_area.visible = phase != DrawGuessGame.Phase.IDLE
	_setup_panel.visible = phase == DrawGuessGame.Phase.IDLE
	_pass_panel.visible = _awaiting_pass and phase == DrawGuessGame.Phase.CHOOSING
	_choose_panel.visible = (not _awaiting_pass) and phase == DrawGuessGame.Phase.CHOOSING
	_result_panel.visible = phase == DrawGuessGame.Phase.ROUND_END
	_final_panel.visible = phase == DrawGuessGame.Phase.FINISHED

	if _awaiting_pass:
		_pass_label.text = tr("把手机交给 %s（本回合画手）") % _name_of(_local())

	_board.set_drawing_enabled(phase == DrawGuessGame.Phase.DRAWING and not _awaiting_pass)
	_update_live()


func _update_live() -> void:
	if _game == null:
		return
	var phase := _game.get_phase()
	_round_label.text = tr("第 %d/%d 回合") % [
		maxi(_game.get_round_index(), 1), _rounds_input.get_selected_id()]

	if phase == DrawGuessGame.Phase.DRAWING or phase == DrawGuessGame.Phase.CHOOSING:
		_timer_label.text = "%d" % int(ceil(_game.get_time_left()))
	else:
		_timer_label.text = ""

	_score_label.text = _score_text()

	if phase == DrawGuessGame.Phase.DRAWING:
		var word := _game.get_word_for(_local())
		_word_label.text = (tr("你要画：%s") % word) if not word.is_empty() else ""
		var others := tr("已猜对 %d/%d") % [_game.get_guessed_count(), _game.get_guesser_total()]
		_hint_label.text = "%s    %s" % [_game.get_hint_text(), others]
	elif phase == DrawGuessGame.Phase.ROUND_END:
		_word_label.text = ""
		_hint_label.text = tr("本回合结束")
	else:
		_word_label.text = ""
		_hint_label.text = ""

	for peer_id in _guesser_buttons:
		var b: Button = _guesser_buttons[peer_id]
		var done := _game.has_guessed(peer_id)
		b.button_pressed = done
		b.disabled = done or phase != DrawGuessGame.Phase.DRAWING


func _rebuild_guesser_panel() -> void:
	if _game == null:
		return
	_clear(_guesser_grid)
	_guesser_buttons.clear()

	_guess_target.clear()
	for p in _game.get_players():
		var peer_id := int(p["peer_id"])
		if _game.is_drawer(peer_id):
			continue
		var b := Button.new()
		b.toggle_mode = true
		b.text = tr("%s 猜对了") % String(p["name"])
		b.custom_minimum_size = Vector2(0, 64)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func():
			_game.on_player_input(_local(), DrawGuessMessages.encode_mark_correct(peer_id)))
		_guesser_grid.add_child(b)
		_guesser_buttons[peer_id] = b

		# 画手不可能同时是猜词者，所以这里的 id 直接作为下拉项
		_guess_target.add_item(String(p["name"]), peer_id)

	_guess_target.select(0)
	_update_live()


func _submit_guess() -> void:
	if _game == null or _game.get_phase() != DrawGuessGame.Phase.DRAWING:
		return
	var text := _guess_input.text.strip_edges()
	if text.is_empty():
		return
	var target := _guess_target.get_selected_id()
	if target == _local():
		_feedback_label.text = tr("画手不能猜词")
		return
	_game.on_player_input(target, DrawGuessMessages.encode_guess(text))
	_guess_input.text = ""


func _on_local_stroke(chunk: PackedByteArray) -> void:
	if _game == null or _game.get_phase() != DrawGuessGame.Phase.DRAWING:
		return
	# 联网后这里改为：房间层广播给其他人。
	# 本机画手的笔迹已经本地渲染过了，不要再 apply 回来，否则会重影。
	_game.on_player_input(_local(), DrawGuessMessages.encode_stroke(chunk))


func _on_clear_pressed() -> void:
	_board.clear_canvas()
	if _game != null and _game.get_phase() == DrawGuessGame.Phase.DRAWING:
		_game.on_player_input(_local(), DrawGuessMessages.encode_clear())


# ------------------------------------------------------------------ 小工具

func _score_text() -> String:
	if _game == null:
		return ""
	var parts := PackedStringArray()
	var scores := _game.get_scores()
	for peer_id in scores:
		var score := int(scores[peer_id])
		if score > 0:
			parts.append("%s %d" % [_name_of(peer_id), score])
	return " · ".join(parts)


func _name_of(peer_id: int) -> String:
	if _game == null:
		return "?"
	for p in _game.get_players():
		if int(p["peer_id"]) == peer_id:
			return String(p["name"])
	return tr("已离开")


func _label(text: String, font_size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	return l


func _button(text: String, font_size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", font_size)
	b.custom_minimum_size = Vector2(0, 56)
	return b


## 热座模式下"本机玩家"就是当前拿着手机的人，也就是画手。
## 必须是函数而不是缓存变量——候选词是在画手选出来之前就下发的，
## 缓存会导致选词报文带着过期的 peer_id 被权威端丢掉。
func _local() -> int:
	return _game.get_drawer_peer_id() if _game != null else 0


func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = SURFACE
	style.set_corner_radius_all(0)
	# 面板内边距。没有它的话内容会顶到屏幕边缘，正文字符被切、按钮贴边。
	style.content_margin_left = 44.0
	style.content_margin_right = 44.0
	style.content_margin_top = 44.0
	style.content_margin_bottom = 44.0
	p.add_theme_stylebox_override("panel", style)
	return p


## 浅色主题。挂在根节点上，整棵界面树都会继承。
func _make_light_theme() -> Theme:
	var t := Theme.new()

	# 每个控件类型都有自己的状态色。只设 font_color 的话，
	# hover / pressed / disabled 会回落到默认主题的浅色，在浅底上直接消失。
	for tname in ["Label", "Button", "OptionButton", "CheckBox", "CheckButton"]:
		t.set_color("font_color", tname, INK)
		t.set_color("font_hover_color", tname, INK)
		t.set_color("font_pressed_color", tname, INK)
		t.set_color("font_focus_color", tname, INK)
		t.set_color("font_disabled_color", tname, INK_DIM)

	t.set_color("font_color", "LineEdit", INK)
	t.set_color("font_placeholder_color", "LineEdit", INK_DIM)
	t.set_color("font_selected_color", "LineEdit", Color.WHITE)
	t.set_color("caret_color", "LineEdit", INK)
	t.set_color("selection_color", "LineEdit", Color(0.66, 0.79, 0.98))

	# 下拉框弹出来的菜单
	t.set_color("font_color", "PopupMenu", INK)
	t.set_color("font_hover_color", "PopupMenu", INK)
	t.set_color("font_disabled_color", "PopupMenu", INK_DIM)
	t.set_stylebox("panel", "PopupMenu", _surface_box(SURFACE))
	t.set_stylebox("hover", "PopupMenu", _surface_box(SURFACE_PRESSED))

	# 按钮底色也要换。默认主题是深灰，黑字压上去比原来还糊。
	for tname in ["Button", "OptionButton", "CheckBox", "CheckButton"]:
		t.set_stylebox("normal", tname, _surface_box(SURFACE_ALT))
		t.set_stylebox("hover", tname, _surface_box(SURFACE))
		t.set_stylebox("pressed", tname, _surface_box(SURFACE_PRESSED))
		t.set_stylebox("disabled", tname, _surface_box(SURFACE_DISABLED))
		t.set_stylebox("focus", tname, _focus_box())

	t.set_stylebox("normal", "LineEdit", _surface_box(SURFACE))
	t.set_stylebox("focus", "LineEdit", _focus_box())

	return t


func _surface_box(color: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(12)
	box.content_margin_left = 18.0
	box.content_margin_right = 18.0
	box.content_margin_top = 10.0
	box.content_margin_bottom = 10.0
	return box


## 键盘焦点圈。背景全透明，只画一圈边，避免盖住正常状态的底色。
func _focus_box() -> StyleBoxFlat:
	var box := _surface_box(Color(1, 1, 1, 0.0))
	box.border_width_top = 3
	box.border_width_bottom = 3
	box.border_width_left = 3
	box.border_width_right = 3
	box.border_color = FOCUS_RING
	return box


func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
