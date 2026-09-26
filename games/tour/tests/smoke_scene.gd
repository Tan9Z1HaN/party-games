extends SceneTree

## 《环游中国》牌桌的界面冒烟测试。
##
##   godot --headless --path . --script res://games/tour/tests/smoke_scene.gd
##
## 逻辑单测跑得再全，也测不出「界面在某个状态下崩了」「按钮该亮的时候不亮」。
## 这里实例化真的牌桌，把它推到各种状态，确认不会崩、按钮状态也对。

var _passed := 0
var _failed := 0
var _scene


func _initialize() -> void:
	print("=== 环游中国 · 界面冒烟测试 ===")
	var packed := load("res://games/tour/main.tscn")
	_check("场景能加载", packed != null)
	if packed == null:
		_finish()
		return
	_scene = packed.instantiate()
	root.add_child(_scene)
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	_check("界面构建完成", _scene._board != null and _scene._round_label != null)
	if _scene._board == null:
		_finish()
		return

	_scene.setup_solo(2)
	await process_frame
	_test_initial()
	_test_cell_tap()
	_test_buttons()
	await _test_play_loop()
	_finish()


func _test_initial() -> void:
	print("\n-- 开局 --")
	_check("3 个人（你 + 2 个电脑）", _scene._rules.players().size() == 3,
		"%d" % _scene._rules.players().size())
	_check("轮次行有内容", _scene._round_label.text.length() > 0,
		_scene._round_label.text)
	_check("顶栏写了每个人的现金", _scene._bar.get_child_count() == 3,
		"%d" % _scene._bar.get_child_count())
	_check("起始时没有人拥有地", _scene._rules.owner_of(14) == 0)


## 格子上只有短名，地价得点开看。这条防的是「点了没反应」。
func _test_cell_tap() -> void:
	print("\n-- 点格子看详情 --")
	_scene._on_cell_tapped(14)
	_check("写进了地价", "地价" in _scene._log_label.text, _scene._log_label.text)
	_check("写明无主", "无主" in _scene._log_label.text, _scene._log_label.text)
	_check("用的是全名（不是格子上那个短名）",
		_scene._log_label.text.begins_with(TourBoard.name_of(14)),
		_scene._log_label.text)

	# 有主之后要显示业主、等级、过路费
	_scene._rules._owner[14] = 2
	_scene._rules._level[14] = 2
	_scene._on_cell_tapped(14)
	_check("写明业主", "业主" in _scene._log_label.text, _scene._log_label.text)
	_check("写明过路费", "过路费" in _scene._log_label.text, _scene._log_label.text)


func _test_buttons() -> void:
	print("\n-- 按钮状态 --")
	# 摆成"轮到真人、可以掷骰"
	_scene._rules._cursor = 0
	_scene._rules._phase = TourRules.Phase.AWAIT_ROLL
	_scene._rules._skip[1] = 0
	_scene._refresh()
	_check("轮到自己时掷骰可点", not _scene._buttons["roll"].disabled)
	_check("这时候买下不可点", _scene._buttons["buy"].disabled)
	_check("这时候放弃不可点（不能拿来跳回合）",
		_scene._buttons["decline"].disabled)

	# 摆成"等真人决定买不买"
	_scene._rules._phase = TourRules.Phase.DECIDING
	_scene._rules._decision = TourRules.Decision.BUY
	_scene._rules._pending_cell = 14
	_scene._refresh()
	_check("要决定时买下可点", not _scene._buttons["buy"].disabled)
	_check("这时候掷骰不可点", _scene._buttons["roll"].disabled)
	_check("这时候放弃可点", not _scene._buttons["decline"].disabled)
	# 提示是画在棋盘中央的，不是日志行——别去日志里找它
	var hint := String(_scene._hint_for(_scene._rules.snapshot()))
	_check("中央提示写明要买哪一块",
		TourBoard.name_of(14) in hint, hint)

	# 轮到电脑时全灰
	_scene._rules._phase = TourRules.Phase.AWAIT_ROLL
	_scene._rules._decision = TourRules.Decision.NONE
	_scene._rules._cursor = 1
	_scene._refresh()
	_check("轮到电脑时掷骰不可点", _scene._buttons["roll"].disabled)

	# 所得税的二选一：平时藏着，落到所得税上才露出来，而且写着各交多少
	_check("平时看不到交税的按钮", not _scene._tax_row.visible)
	_scene._rules._cursor = 0
	_scene._rules._phase = TourRules.Phase.DECIDING
	_scene._rules._decision = TourRules.Decision.TAX
	_scene._rules._pending_cell = 4
	_scene._rules._pos[1] = 4
	_scene._refresh()
	_check("落到所得税上就露出两个选项", _scene._tax_row.visible)
	_check("固定值写在按钮上",
		"200" in _scene._tax_flat_button.text, _scene._tax_flat_button.text)
	_check("按比例的金额也写出来了",
		"60" in _scene._tax_percent_button.text, _scene._tax_percent_button.text)
	_check("这时候主按钮都点不动",
		_scene._buttons["roll"].disabled and _scene._buttons["buy"].disabled)

	# 抽卡动画：靠序号发现"又来了一张新卡"，放完自己收掉
	_scene._rules._last_card = {"text": "测试：收 200", "chance": true}
	_scene._rules._card_seq += 1
	_scene._refresh()
	_check("抽到新卡会开始放动画", _scene._card_t >= 0.0, "%f" % _scene._card_t)
	_scene._step_card(0.5)
	_check("动画推进后棋盘中央有卡", not _scene._board._card.is_empty())
	_scene._step_card(2.0)
	_check("动画放完自己收掉", _scene._board._card.is_empty())
	# 同一个文案连着抽到两次也要各放一次——所以才用序号而不是比文案
	_scene._rules._card_seq += 1
	_scene._refresh()
	_check("同一条文案再抽到还会再放", _scene._card_t >= 0.0)


## 让 AI 把一局打完，过程中界面每步都刷新一次。
func _test_play_loop() -> void:
	print("\n-- 把一局推到底 --")
	var steps := 0
	while not _scene._rules.is_finished() and steps < 4000:
		steps += 1
		TourAi.act(_scene._rules, _scene._rules.current_player())
		_scene._refresh()
		if steps % 60 == 0:
			await process_frame
	_check("整局能跑完", _scene._rules.is_finished(), "%d 步" % steps)
	_check("过程中界面没崩", _scene._board != null and _scene._log_label != null)
	_check("结束时重开按钮露出来", _scene._buttons["again"].visible)
	var ranking: Array = _scene._rules.ranking()
	_check("排名人数对得上", ranking.size() == 3, "%d" % ranking.size())


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] ", label, "   ", detail)


func _finish() -> void:
	print("\n=== 通过 %d，失败 %d ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
