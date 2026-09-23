extends SceneTree

## 界面冒烟测试：真的把 main.tscn 实例化出来，然后像玩家一样点按钮走完一局。
##
## 运行方式：
##   godot --headless --path . --script res://games/draw_guess/tests/smoke_scene.gd
##
## 为什么需要它：逻辑单测跑得再全，也测不出「按钮连错信号」「界面刷新时读了过期变量」
## 这一类接线问题。这里把整条链路真的走一遍。

var _passed := 0
var _failed := 0
var _scene


func _initialize() -> void:
	print("=== 你画我猜 · 界面冒烟测试 ===")

	var packed = load("res://games/draw_guess/main.tscn")
	_check("场景能加载", packed != null)
	if packed == null:
		_finish()
		return

	_scene = packed.instantiate()
	root.add_child(_scene)
	_run()


## 必须等一帧再断言：_initialize() 阶段场景树还没开始运转，
## 这时候 root.add_child() 不会触发节点的 _ready()，界面还没被构建出来。
func _run() -> void:
	await process_frame
	await process_frame

	_check("界面构建完成", _scene._board != null and _scene._setup_panel != null)
	if _scene._board == null:
		_finish()
		return

	_test_setup_screen()
	_test_start_game()
	_test_choose_word()
	_test_drawing_phase()
	_test_typing_guess()
	_test_marking_guessed()
	_test_finish_and_restart()
	_test_fatal_error_screen()

	_finish()


func _test_setup_screen() -> void:
	print("\n-- 起始界面 --")
	_check("起始显示设置面板", _scene._setup_panel.visible)
	_check("起始隐藏游戏区", not _scene._play_area.visible)
	_check("难度有三档", _scene._difficulty_input.item_count == 3)
	_check("人数从 3 起", _scene._player_count.item_count == 6, "%d" % _scene._player_count.item_count)
	_check("回合数是下拉框", _scene._rounds_input is OptionButton)
	_check("时长是下拉框", _scene._seconds_input is OptionButton)
	_test_contrast()


## 浅色底 + 黑字必须成套。只改一头就会出现「浅字压浅底」那种读不出来的情况，
## 而且按钮的 hover / pressed / disabled 各有独立的颜色，漏一个都会翻车。
func _test_contrast() -> void:
	var theme: Theme = _scene.theme
	_check("挂了主题", theme != null)
	if theme == null:
		return

	var label_ink: Color = theme.get_color("font_color", "Label")
	_check("正文是深色", label_ink.v < 0.3, str(label_ink))

	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		var c: Color = theme.get_color(state, "Button")
		_check("按钮 %s 是深色" % state, c.v < 0.3, str(c))

	for tname in ["Button", "OptionButton"]:
		var box := theme.get_stylebox("normal", tname) as StyleBoxFlat
		_check("%s 底色是浅色" % tname, box != null and box.bg_color.v > 0.85, str(box))

	var disabled: Color = theme.get_color("font_disabled_color", "Button")
	var disabled_box := theme.get_stylebox("disabled", "Button") as StyleBoxFlat
	_check("禁用态仍然可读", disabled_box != null and absf(disabled.v - disabled_box.bg_color.v) > 0.25,
		"字 %s / 底 %s" % [str(disabled), str(disabled_box)])

	var edit_ink: Color = theme.get_color("font_color", "LineEdit")
	_check("输入框文字是深色", edit_ink.v < 0.3, str(edit_ink))


func _test_start_game() -> void:
	print("\n-- 开始游戏 --")
	_scene._player_count.select(1)          # 4 人
	_scene._rounds_input.select(0)          # 1 回合
	_scene._seconds_input.select(1)         # 60 秒
	_scene._start_game()

	var game = _scene._game
	_check("游戏对象已建立", game != null)
	_check("4 名玩家", game.get_players().size() == 4)
	_check("进入选词阶段", game.get_phase() == DrawGuessGame.Phase.CHOOSING)
	_check("进入游戏区", _scene._play_area.visible)
	_check("设置面板隐藏", not _scene._setup_panel.visible)
	_check("先显示交接手机面板", _scene._pass_panel.visible)
	_check("交接面板写明了画手", _scene._pass_label.text.length() > 0)


func _test_choose_word() -> void:
	print("\n-- 选词 --")
	# 玩家点"我准备好了"
	_scene._awaiting_pass = false
	_scene._refresh()
	_check("选词面板出现", _scene._choose_panel.visible)
	_check("给了三个候选", _scene._choose_box.get_child_count() == 3,
		"%d" % _scene._choose_box.get_child_count())

	var first = _scene._choose_box.get_child(0)
	first.pressed.emit()

	var game = _scene._game
	_check("进入作画阶段", game.get_phase() == DrawGuessGame.Phase.DRAWING)
	_check("画手看得到词", not game.get_word_for(game.get_drawer_peer_id()).is_empty())
	_check("画板可画", _scene._board.is_drawing_enabled())
	_check("猜词按钮数量 = 3", _scene._guesser_buttons.size() == 3,
		"%d" % _scene._guesser_buttons.size())


func _test_drawing_phase() -> void:
	print("\n-- 作画 --")
	var game = _scene._game
	var drawer: int = game.get_drawer_peer_id()

	# 模拟画板吐出一段笔迹，走的是和真实触摸一样的信号路径
	var chunk := StrokeCodec.encode_chunk(1, StrokeCodec.FLAG_BEGIN, 0, 1,
		PackedVector2Array([Vector2(100, 100), Vector2(120, 130)]))
	_scene._board.stroke_chunk.emit(chunk)
	_check("画手作画时不会报错", true)

	# 非画手画应该被权威端丢掉，且这里的本地画板本来就该是关的
	_check("画手身份与界面一致", _scene._local() == drawer)
	_check("计时器有显示", _scene._timer_label.text.length() > 0)
	_check("提示带掩码", _scene._hint_label.text.contains("_"), _scene._hint_label.text)
	_check("画手能看到词", _scene._word_label.text.contains(
		game.get_word_for(drawer)), _scene._word_label.text)


func _test_typing_guess() -> void:
	print("\n-- 打字猜词 --")
	var game = _scene._game
	var word: String = game.get_word_for(game.get_drawer_peer_id())

	_scene._guess_target.select(0)
	var target: int = _scene._guess_target.get_selected_id()
	_check("选中的不是画手", target != game.get_drawer_peer_id())

	_scene._guess_input.text = "肯定不是这个词"
	_scene._submit_guess()
	_check("错误猜测有反馈", _scene._feedback_label.text.length() > 0)
	_check("错误猜测不记分", not game.has_guessed(target))

	_scene._guess_input.text = word
	_scene._submit_guess()
	_check("正确猜测被记录", game.has_guessed(target))
	_check("输入框已清空", _scene._guess_input.text == "")
	_check("反馈提示猜对", _scene._feedback_label.text.contains("猜对"),
		_scene._feedback_label.text)


func _test_marking_guessed() -> void:
	print("\n-- 标记全部猜对 --")
	var game = _scene._game
	var ids: Array = _scene._guesser_buttons.keys()
	for peer_id in ids:
		if not _scene._guesser_buttons.has(peer_id):
			continue
		var button = _scene._guesser_buttons[peer_id]
		if is_instance_valid(button):
			button.pressed.emit()

	_check("三人全部猜对", game.get_guessed_count() == 3, "%d" % game.get_guessed_count())
	_check("自动进入结算", game.get_phase() == DrawGuessGame.Phase.ROUND_END)
	_check("结算面板显示", _scene._result_panel.visible)
	_check("结算写明答案", _scene._result_title.text.contains(
		game.get_revealed_word()), _scene._result_title.text)
	_check("结算列出得分行", _scene._result_rows.get_child_count() > 0)
	_check("画板已禁用", not _scene._board.is_drawing_enabled())


func _test_finish_and_restart() -> void:
	print("\n-- 结束与再来一局 --")
	var game = _scene._game
	game.advance_now()
	_check("一回合跑完后结束", game.is_finished())
	_check("最终面板显示", _scene._final_panel.visible)
	_check("排名有 4 行", _scene._final_rows.get_child_count() == 4,
		"%d" % _scene._final_rows.get_child_count())

	var champion: int = int(game.get_results()[0]["peer_id"])
	_check("冠军有分", int(game.get_scores()[champion]) > 0)

	_scene._show_setup()
	_check("回到设置界面", _scene._setup_panel.visible and _scene._game == null)


func _test_fatal_error_screen() -> void:
	print("\n-- 出错页 --")
	_scene._on_fatal_error("测试用的错误信息")
	_check("出错页显示", _scene._error_panel.visible)
	_check("设置页隐藏", not _scene._setup_panel.visible)
	_check("游戏区隐藏", not _scene._play_area.visible)
	_check("错误文案写进去了", _scene._error_label.text.contains("测试"),
		_scene._error_label.text)

	_scene._show_setup()
	_check("返回后回到设置页", _scene._setup_panel.visible and not _scene._error_panel.visible)


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  [OK]   ", label)
	else:
		_failed += 1
		print("  [FAIL] ", label, "   ", detail)


func _finish() -> void:
	print("\n=== 通过 %d，失败 %d ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
