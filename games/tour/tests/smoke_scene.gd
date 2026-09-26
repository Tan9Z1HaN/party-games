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
	_test_view()
	_test_draw_call_sites()
	await _test_play_loop()
	await _test_result()
	_finish()


func _test_initial() -> void:
	print("\n-- 开局 --")
	_check("3 个人（你 + 2 个电脑）", _rules().players().size() == 3,
		"%d" % _rules().players().size())
	_check("轮次行有内容", _scene._round_label.text.length() > 0,
		_scene._round_label.text)
	_check("顶栏写了每个人的现金", _scene._bar.get_child_count() == 3,
		"%d" % _scene._bar.get_child_count())
	_check("起始时没有人拥有地", _rules().owner_of(14) == 0)
	_check("还没打完就不弹结算", not _scene._result_layer.visible)


## 格子上只有短名，地价得点开看。这条防的是「点了没反应」。
func _test_cell_tap() -> void:
	print("\n-- 点格子看详情 --")
	_scene._on_cell_tapped(14)
	_check("写进了地价", "地价" in _scene._log_label.text, _scene._log_label.text)
	_check("写明无主", "无主" in _scene._log_label.text, _scene._log_label.text)
	# 无主的地没有业主、没有等级，也不该报过路费——报「过路费 0」等于说废话
	_check("无主的地不报过路费", "过路费" not in _scene._log_label.text,
		_scene._log_label.text)
	_check("用的是全名（不是格子上那个短名）",
		_scene._log_label.text.begins_with(TourBoard.name_of(14)),
		_scene._log_label.text)

	# 有主之后要显示业主、等级、过路费
	_rules()._owner[14] = 2
	_rules()._level[14] = 2
	_scene._on_cell_tapped(14)
	_check("写明业主", "业主" in _scene._log_label.text, _scene._log_label.text)
	_check("写明过路费", "过路费" in _scene._log_label.text, _scene._log_label.text)


func _test_buttons() -> void:
	print("\n-- 按钮状态 --")
	# 摆成"轮到真人、可以掷骰"
	_rules()._cursor = 0
	_rules()._phase = TourRules.Phase.AWAIT_ROLL
	_rules()._skip[1] = 0
	_scene._refresh()
	_check("轮到自己时掷骰可点", not _scene._buttons["roll"].disabled)
	_check("这时候买下不可点", _scene._buttons["buy"].disabled)
	_check("这时候放弃不可点（不能拿来跳回合）",
		_scene._buttons["decline"].disabled)

	# 摆成"等真人决定买不买"
	_rules()._phase = TourRules.Phase.DECIDING
	_rules()._decision = TourRules.Decision.BUY
	_rules()._pending_cell = 14
	_scene._refresh()
	_check("要决定时买下可点", not _scene._buttons["buy"].disabled)
	_check("这时候掷骰不可点", _scene._buttons["roll"].disabled)
	_check("这时候放弃可点", not _scene._buttons["decline"].disabled)
	# 提示是画在棋盘中央的，不是日志行——别去日志里找它
	var hint := String(_scene._hint_for(_rules().snapshot()))
	_check("中央提示写明要买哪一块",
		TourBoard.name_of(14) in hint, hint)

	# 轮到电脑时全灰
	_rules()._phase = TourRules.Phase.AWAIT_ROLL
	_rules()._decision = TourRules.Decision.NONE
	_rules()._cursor = 1
	_scene._refresh()
	_check("轮到电脑时掷骰不可点", _scene._buttons["roll"].disabled)

	# 所得税的二选一：平时藏着，落到所得税上才露出来，而且写着各交多少
	_check("平时看不到交税的按钮", not _scene._tax_row.visible)
	_rules()._cursor = 0
	_rules()._phase = TourRules.Phase.DECIDING
	_rules()._decision = TourRules.Decision.TAX
	_rules()._pending_cell = 4
	_rules()._pos[1] = 4
	_scene._refresh()
	_check("落到所得税上就露出两个选项", _scene._tax_row.visible)
	_check("固定值写在按钮上",
		"200" in _scene._tax_flat_button.text, _scene._tax_flat_button.text)
	_check("按比例的金额也写出来了",
		"60" in _scene._tax_percent_button.text, _scene._tax_percent_button.text)
	_check("这时候主按钮都点不动",
		_scene._buttons["roll"].disabled and _scene._buttons["buy"].disabled)

	# 抽卡动画：靠序号发现"又来了一张新卡"，放完自己收掉
	_rules()._last_card = {"text": "测试：收 200", "chance": true}
	_rules()._card_seq += 1
	_scene._refresh()
	_check("抽到新卡会开始放动画", _scene._card_t >= 0.0, "%f" % _scene._card_t)
	_scene._step_card(0.5)
	_check("动画推进后棋盘中央有卡", not _scene._board._card.is_empty())
	_scene._step_card(2.0)
	_check("动画放完自己收掉", _scene._board._card.is_empty())
	# 同一个文案连着抽到两次也要各放一次——所以才用序号而不是比文案
	_rules()._card_seq += 1
	_scene._refresh()
	_check("同一条文案再抽到还会再放", _scene._card_t >= 0.0)


## 棋子的落点、逐格跳的节奏、骰子摇动、收付飘字。
##
## 这几条全是"看得见"的东西，而测试看不见画面——所以尽量把它们做成
## 可以算的数值（时长、落点表、飘字文本），剩下的交给截图工具。
func _test_view() -> void:
	print("\n-- 棋子与动画节奏 --")

	# 棋子：每个还活着的人都要算出一个落点。
	# 这段原来被误插进 _draw_card_anim() 里，结果平时满盘看不到人。
	var placements: Array = _scene._board.token_placements(_rules().snapshot())
	_check("每个活着的人都有棋子", placements.size() == 3, "%d 个" % placements.size())
	_check("棋子带着所在格", placements[0].has("cell"), str(placements[0]))
	# 两个人站在同一格要散开，不能叠成一个点
	var stacked := {"players": [
		{"peer_id": 1, "name": "甲", "cash": 0, "assets": 0, "pos": 7, "out": false, "skip": 0},
		{"peer_id": 2, "name": "乙", "cash": 0, "assets": 0, "pos": 7, "out": false, "skip": 0},
	]}
	var same_cell: Array = _scene._board.token_placements(stacked)
	_check("同格的两个人算成两条", same_cell.size() == 2, "%d" % same_cell.size())
	_check("同格要有散开的序号", int(same_cell[0]["index"]) != int(same_cell[1]["index"]))
	_check("散开的间距按同格人数算", int(same_cell[0]["count"]) == 2)
	# 出局的人不该还有棋子
	var gone := {"players": [
		{"peer_id": 1, "name": "甲", "cash": 0, "assets": 0, "pos": 3, "out": true, "skip": 0},
	]}
	_check("出局的人没有棋子", _scene._board.token_placements(gone).is_empty())

	# 逐格跳的节奏**按格数算**：走 12 格不能和走 1 格一样快慢
	_scene._start_hop(1, 0, 1)
	var one_step := float(_scene._hop["total"])
	_scene._start_hop(1, 0, 12)
	var long_step := float(_scene._hop["total"])
	_check("走一格和走十二格用不同的时长", long_step > one_step,
		"%.2f vs %.2f" % [one_step, long_step])
	_check("一格也看得见（有下限）", one_step >= 0.2 - 0.001, "%.2f" % one_step)
	_check("长距离不会拖到看不清（有上限）", long_step <= 0.9 + 0.001, "%.2f" % long_step)

	# 方向：抽到「后退 2 格」要往回跳，不能横穿整张棋盘
	_scene._start_hop(1, 5, 3)
	_check("后退就是往回走", int(_scene._hop["steps"]) == -2,
		"%d" % int(_scene._hop["steps"]))
	_scene._start_hop(1, 39, 1)
	_check("绕过出发算前进两格", int(_scene._hop["steps"]) == 2,
		"%d" % int(_scene._hop["steps"]))

	# 跳完要在落点上亮一下
	_scene._start_hop(1, 0, 3)
	_scene._step_hop(5.0)
	_check("跳完亮起落地那格", int(_scene._flash.get("cell", -1)) == 3, str(_scene._flash))
	_check("跳完把插值位置收掉", _scene._board._moving.is_empty())
	_scene._step_flash(0.3)
	_check("高亮会衰减", float(_scene._flash.get("t", 0.0)) < 0.7)
	_scene._step_flash(2.0)
	_check("高亮放完自己收掉", _scene._flash.is_empty())

	# 骰子先摇一下再落定：直接蹦出点数没有"掷"的感觉
	_rules()._last_dice = [1, 1]
	_scene._refresh()
	_rules()._last_dice = [5, 6]
	_scene._refresh()
	_check("换了点数就开始摇", _scene._dice_t >= 0.0, "%f" % _scene._dice_t)
	_check("摇的时候不报点数", "掷骰中" in _scene._dice_label.text, _scene._dice_label.text)
	_scene._step_dice(1.0)
	_check("摇完写出总数", "11" in _scene._dice_label.text, _scene._dice_label.text)

	# 钱的进出在顶栏挂一下，不然什么时候变的全靠盯数字
	_rules()._cash[1] += 250
	_scene._refresh()
	_check("收钱挂了飘字", not _scene._cash_flash.is_empty(), str(_scene._cash_flash))
	_check("顶栏写明了加多少", "+250" in _bar_text(), _bar_text())
	# 飘字是单独一个标签：名字那块该保留玩家自己的颜色，不能被红绿淹没
	var chip: Control = _scene._bar.get_child(0)
	_check("飘字和名字分成两块", chip.get_child_count() == 2,
		"%d 块" % chip.get_child_count())
	_check("名字还是玩家色",
		chip.get_child(0).get_theme_color("font_color") == _scene._board.color_of(1),
		str(chip.get_child(0).get_theme_color("font_color")))
	_scene._step_cash_flash(2.0)
	_check("飘字到点自己收掉", _scene._cash_flash.is_empty())
	_check("飘字收掉之后只剩名字一块", _scene._bar.get_child(0).get_child_count() == 1)


## 画棋子的那段必须挂在 _draw() 上。
##
## 它原来被误插进 _draw_card_anim()，结果只有翻卡的那一瞬间棋子才画得出来，
## 平时满盘看不到人。headless 不渲染，单测拿不到画面，只能退一步盯调用位置。
func _test_draw_call_sites() -> void:
	print("\n-- 绘制入口 --")
	var src := _source_of("res://games/tour/ui/board_view.gd")
	_check("能读到棋盘源码", not src.is_empty())
	_check("_draw() 里画棋子", _body_of(src, "func _draw() -> void:").contains("_draw_tokens("))
	_check("_draw() 里画棋盘",
		_body_of(src, "func _draw() -> void:").contains("_draw_cell("))
	# 用 "_draw_token" 而不是 "_draw_tokens(" 来查：当年那段是直接内联写进去的，
	# 只认函数名的话，同样的错误再犯一次反而查不出来。
	_check("抽卡函数不画棋子",
		not _body_of(src, "func _draw_card_anim(font: Font) -> void:").contains("_draw_token"))


## 结算面板：一局打完盖在棋盘上，列出资产排名。
func _test_result() -> void:
	print("\n-- 结算面板 --")
	_check("打完自动弹出结算", _scene._result_layer.visible)
	_check("结算写了赢家", _scene._result_title.text.length() > 0,
		_scene._result_title.text)
	_check("结算写了本机名次", _scene._result_sub.text.length() > 0,
		_scene._result_sub.text)
	# 标题永远是「XX 赢了」，副标题再写一遍「你赢了」就是废话
	_check("标题写了赢家", "赢了" in _scene._result_title.text, _scene._result_title.text)
	_check("副标题不重复标题那句", "赢了" not in _scene._result_sub.text,
		_scene._result_sub.text)
	_check("结算列全了每个人", _scene._result_rows.get_child_count() == 3,
		"%d 行" % _scene._result_rows.get_child_count())
	_check("单机给「再来一局」", _scene._result_again.visible)

	# 名次排序：活着的人排前面，出局的排后面
	var fake := {"players": [
		{"peer_id": 1, "name": "甲", "cash": 0, "assets": 0, "pos": 0, "out": false, "skip": 0},
		{"peer_id": 2, "name": "乙", "cash": 900, "assets": 900, "pos": 0, "out": false, "skip": 0},
		{"peer_id": 3, "name": "丙", "cash": 0, "assets": 0, "pos": 0, "out": true, "skip": 0},
	]}
	var ordered: Array = _scene._standings(fake)
	_check("资产高的排前面", int(ordered[0]["peer_id"]) == 2)
	_check("活着但两手空空，也排在出局的人前面", int(ordered[1]["peer_id"]) == 1)
	_check("出局的排最后", int(ordered[2]["peer_id"]) == 3)

	# 玩家点「看棋盘」收掉之后，别再自己弹回来
	_scene._result_layer.visible = false
	_scene._refresh()
	_check("收掉之后不会再弹", not _scene._result_layer.visible)

	# 「屏幕显示不全」是这个项目反复踩到的坑：6 个人挤在一个面板里也得放得下
	var many := {"finished": true, "players": []}
	for i in 6:
		many["players"].append({
			"peer_id": i + 1, "name": "玩家%d" % (i + 1),
			"cash": 500 + i, "assets": 900 + i, "pos": 0, "out": i >= 4, "skip": 0,
		})
	_scene._update_result(many)
	await process_frame
	await process_frame
	var card: Control = _scene._result_layer.get_child(0)
	_check("结算列了 6 个人", _scene._result_rows.get_child_count() == 6,
		"%d 行" % _scene._result_rows.get_child_count())
	# 不比屏幕坐标，比**内容要多大**：headless 里容器不一定做过布局，
	# 但最小尺寸是算得出来的，而"塞不下"正是这一条要防的。
	var need := card.get_combined_minimum_size()
	_check("六个人的结算窄得过手机屏（1080）", need.x <= 1080.0, str(need))
	_check("六个人的结算矮得过一屏，还留得下棋盘", need.y <= 1100.0, str(need))
	print("      六个人的结算最小尺寸 %s" % need)


func _source_of(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


## 顶栏那片文字拼起来。每个玩家是一小块（名字 + 可选的收付飘字），
## 所以不能直接读 child.text。
func _bar_text() -> String:
	var parts := PackedStringArray()
	for chip in _scene._bar.get_children():
		for piece in chip.get_children():
			parts.append(String(piece.text))
	return " ".join(parts)


## 取某个函数（从它的声明到下一个顶层 func）之间的源码。
func _body_of(src: String, header: String) -> String:
	var start := src.find(header)
	if start < 0:
		return ""
	var rest := src.substr(start + header.length())
	var stop := rest.find("\nfunc ")
	if stop >= 0:
		rest = rest.substr(0, stop)
	return rest


## 让 AI 把一局打完，过程中界面每步都刷新一次。
func _test_play_loop() -> void:
	print("\n-- 把一局推到底 --")
	var steps := 0
	while not _rules().is_finished() and steps < 4000:
		steps += 1
		TourAi.act(_rules(), _rules().current_player())
		_scene._refresh()
		if steps % 60 == 0:
			await process_frame
	_check("整局能跑完", _rules().is_finished(), "%d 步" % steps)
	_check("过程中界面没崩", _scene._board != null and _scene._log_label != null)
	_check("结束时重开按钮露出来", _scene._buttons["again"].visible)
	var ranking: Array = _rules().ranking()
	_check("排名人数对得上", ranking.size() == 3, "%d" % ranking.size())


func _rules() -> TourRules:
	## 牌桌改成纯视图之后，规则对象在游戏层里，通过 rules() 拿。
	return _scene._game.rules()

func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] ", label, "   ", detail)


func _finish() -> void:
	print("\n=== 通过 %d，失败 %d ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
