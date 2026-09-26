extends Control

## 《环游中国》牌桌。**这一层是纯视图**：只认 TourGame 给的状态字典，
## 自己不碰规则，也分不清对面是 AI 还是网络上的真人。
##
## 大富翁是轮流制，所以单机只能是「一个真人 + 若干 AI」：同屏热座会让
## 后面的人看见前面的人的钱和地，一台手机传着玩也太慢。
##
## 数据流和 UNO 那边一模一样：输入只走 _game.submit(报文)，
## 状态只从 _game.state() 读。单机时 submit 直接进本地规则，联机时由房间层
## 转给房主——界面这一层完全不用分叉。

signal exit_requested

const LOCAL_PEER := 1
const MAX_AI := 4               ## 一台手机上最多几个电脑对手
const HOP_TIME := 0.35          ## 棋子逐格跳的总时长
const CARD_TIME := 1.5          ## 抽卡动画的总时长

var _game: TourGame
var _room: Room = null
var _players: Array = []
var _board: TourBoardView
var _bar: HBoxContainer
var _round_label: Label
var _log_label: Label
var _dice_label: Label
var _buttons := {}
var _tax_row: HBoxContainer
var _tax_flat_button: Button
var _tax_percent_button: Button

var _busy := false
## 逐格跳动的动画：{peer, from, distance, elapsed}
var _hop := {}
var _card_t := -1.0             ## 抽卡动画的进度，负值表示没在放
var _card_seq := -1             ## 已经放过的卡号，用来发现「又来了一张新的」
## 上一次看到的状态，用来发现「谁动了」「骰子换了」——单机和联机都靠它，
## 这样动画逻辑只有一份，不用管状态是本地算的还是网络送来的。
var _prev_pos := {}
var _prev_dice := []


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = LightTheme.build()
	add_child(LightTheme.backdrop())
	_build_ui()


# ---------------------------------------------------------------- 开局

func setup_solo(ai_count := 2) -> void:
	var count := clampi(ai_count, 1, MAX_AI)
	var names := ["小红", "小蓝", "小绿", "小黄"]
	var roster: Array = [{"peer_id": LOCAL_PEER, "name": tr("你"), "is_ai": false}]
	for i in count:
		roster.append({
			"peer_id": LOCAL_PEER + i + 1,
			"name": names[i],
			"is_ai": true,
		})
	_room = null
	_start_game(roster, {})
	if _game != null:
		_game.start_round()


## 联机入口。app.gd 收到开局广播后调用，两端都会走这里。
func setup_networked(room: Room, players: Array, config: Dictionary) -> void:
	_room = room
	_start_game(players, config)
	if _game == null:
		return
	_game.bind_room(room)

	room.attach_game(_game)
	room.game_snapshot.connect(_on_net_snapshot)
	# 开局由房主发起。客户端等主机发来的第一份快照。
	if room.is_host():
		_game.start_round()


## 造一个 TourGame 并接上信号。单机和联机共用。
func _start_game(players: Array, config: Dictionary) -> void:
	if _game != null:
		_game.queue_free()
	_game = TourGame.new()
	_game.name = "TourGame"
	add_child(_game)
	_game.state_changed.connect(_refresh)
	_players = players
	_game.setup(players, config)
	_busy = false
	_hop.clear()
	_card_t = -1.0
	_card_seq = -1
	_prev_pos.clear()
	_prev_dice = []
	_refresh()


func _on_net_snapshot(snapshot: Dictionary) -> void:
	if _game != null:
		_game.apply_snapshot(snapshot)


## 本机是哪个 peer。单机时是玩家列表里第一个不是 AI 的。
func local_peer() -> int:
	return _game.local_peer_id() if _game != null else LOCAL_PEER


# ---------------------------------------------------------------- 界面

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)

	# 顶部：每个人一行「色点 名字 现金」
	_bar = HBoxContainer.new()
	_bar.add_theme_constant_override("separation", 14)
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_bar)

	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_round_label = LightTheme.label("", 30)
	head.add_child(_round_label)
	_dice_label = LightTheme.label("", 30)
	head.add_child(_dice_label)
	box.add_child(head)

	# 中间：棋盘。它自己撑满可用区域（竖屏上是竖长条）
	_board = TourBoardView.new()
	_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board.cell_tapped.connect(_on_cell_tapped)
	box.add_child(_board)

	_log_label = LightTheme.label("", 28)
	_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log_label.custom_minimum_size = Vector2(0, 76)
	box.add_child(_log_label)

	# 所得税的二选一单独占一排：只在落到所得税上时出现，
	# 常年摆着会跟主按钮抢位置，也会让人以为随时能点。
	_tax_row = HBoxContainer.new()
	_tax_row.add_theme_constant_override("separation", 10)
	_tax_row.visible = false
	box.add_child(_tax_row)
	_tax_flat_button = LightTheme.button("", 30)
	_tax_flat_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tax_flat_button.pressed.connect(_on_tax_flat)
	_tax_row.add_child(_tax_flat_button)
	_tax_percent_button = LightTheme.button("", 30)
	_tax_percent_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tax_percent_button.pressed.connect(_on_tax_percent)
	_tax_row.add_child(_tax_percent_button)

	# 按钮分两排：上面是当前这一步能做的动作，下面是随时可点的杂项。
	# 挤成一排的话，六个按钮每人才 160 像素，中文两三个字就顶满了。
	_add_button_row(box, [
		{"id": "roll", "text": tr("掷骰"), "call": _on_roll},
		{"id": "buy", "text": tr("买下"), "call": _on_buy},
		{"id": "upgrade", "text": tr("升级"), "call": _on_upgrade},
		{"id": "decline", "text": tr("放弃"), "call": _on_decline},
	])
	_add_button_row(box, [
		{"id": "fine", "text": tr("交罚款"), "call": _on_pay_fine},
		{"id": "again", "text": tr("重开一局"), "call": _on_again},
		{"id": "exit", "text": tr("退出"), "call": func(): exit_requested.emit()},
	])


func _add_button_row(parent: Control, specs: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
	for spec in specs:
		var button := LightTheme.button(String(spec["text"]), 30)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(spec["call"])
		row.add_child(button)
		_buttons[String(spec["id"])] = button


## 重开一局。**只有单机有这条路**——联机时按钮是藏起来的：
## 重发要所有人看到同一副局面，客户端自己重发只会跟主机对不上。
func _on_again() -> void:
	setup_solo(MAX_AI)


# ---------------------------------------------------------------- 刷新

func _refresh() -> void:
	if _game == null:
		return
	var state := _game.state()
	if state.is_empty():
		return

	_catch_up_animations(state)
	state["hint"] = _hint_for(state)
	_refresh_bar(state)
	_board.apply(state)
	_board.selected_cell = -1
	# 胜利条件是搞破产，没有总轮数可显示；改成报「还剩几个人」
	_round_label.text = tr("第 %d 轮　还剩 %d 人") % [
		int(state.get("round", 1)), int(state.get("alive", 0))]
	_log_label.text = String(state.get("log", ""))
	_refresh_buttons(state)


## 从状态的变化里发现「有人动了」「骰子换了」「抽到新卡了」，然后放动画。
##
## 靠**对比前后两份状态**，而不是靠事件回调：单机时状态是本地算的，
## 联机时是每 0.25 秒送来的，对比出来一模一样，动画逻辑就只有一份。
func _catch_up_animations(state: Dictionary) -> void:
	for row in state.get("players", []):
		var peer := int(row["peer_id"])
		var pos := int(row["pos"])
		if bool(row["out"]):
			_prev_pos.erase(peer)
			continue
		if _prev_pos.has(peer) and int(_prev_pos[peer]) != pos:
			_start_hop(peer, int(_prev_pos[peer]), pos)
		_prev_pos[peer] = pos

	var dice: Array = state.get("dice", [])
	if dice.size() == 2 and str(dice) != str(_prev_dice):
		_prev_dice = dice.duplicate()
		_show_dice(dice)

	# 抽到新卡就放动画。靠序号判断，不靠对比文案——同一条文案可能连着抽到。
	if int(state.get("card_seq", 0)) != _card_seq:
		_card_seq = int(state.get("card_seq", 0))
		if not (state.get("card", {}) as Dictionary).is_empty():
			_card_t = 0.0


## 棋盘中央那行提示：告诉玩家现在该干什么。
## 状态行只说「轮到谁」，这里要说「要你做什么」。
func _hint_for(state: Dictionary) -> String:
	if bool(state.get("finished", false)):
		var rows := _game.get_results()
		if rows.is_empty():
			return tr("本局结束")
		return tr("%s 赢了！") % _name_of(int(rows[0]["peer_id"]))
	var current := int(state.get("current", 0))
	if current != local_peer():
		return tr("%s 的回合…") % _name_of(current)
	match int(state.get("phase", 0)):
		TourRules.Phase.DECIDING:
			var cell := int(state.get("pending_cell", -1))
			match int(state.get("decision", 0)):
				TourRules.Decision.BUY:
					return tr("要买下 %s 吗？") % TourBoard.name_of(cell)
				TourRules.Decision.UPGRADE:
					return tr("要升级 %s 吗？") % TourBoard.name_of(cell)
				TourRules.Decision.TAX:
					return tr("个人所得税：选一种交法")
			return tr("等着你决定")
	if _row_of(state, local_peer()).get("skip", 0) > 0:
		return tr("你在滞留区，掷骰会等一回合")
	return tr("轮到你了")


func _refresh_bar(state: Dictionary) -> void:
	for child in _bar.get_children():
		_bar.remove_child(child)
		child.queue_free()
	for row in state.get("players", []):
		var peer := int(row["peer_id"])
		var line := "%s %d" % [String(row["name"]), int(row["cash"])]
		if bool(row["out"]):
			line = "%s 出局" % String(row["name"])
		var chip := LightTheme.label(line, 26)
		chip.add_theme_color_override("font_color",
			_board.color_of(peer) if not bool(row["out"]) else Color(0.6, 0.6, 0.62))
		if peer == int(state.get("current", 0)):
			chip.text = "▶ " + line
		_bar.add_child(chip)


func _refresh_buttons(state: Dictionary) -> void:
	var mine := int(state.get("current", 0)) == local_peer() and not _busy
	var phase := int(state.get("phase", 0))
	var decision := int(state.get("decision", 0))
	var finished := bool(state.get("finished", false))
	_buttons["roll"].disabled = not (mine and phase == TourRules.Phase.AWAIT_ROLL)
	_buttons["buy"].disabled = not (mine and phase == TourRules.Phase.DECIDING
		and decision == TourRules.Decision.BUY)
	_buttons["upgrade"].disabled = not (mine and phase == TourRules.Phase.DECIDING
		and decision == TourRules.Decision.UPGRADE)
	# 「放弃」在需要决定的时候才点得动；没得决定时不能拿来跳回合
	_buttons["decline"].disabled = not (mine and phase == TourRules.Phase.DECIDING)
	# 交罚款：只有轮到自己、人在滞留区、钱也够的时候能点
	var mine_row := _row_of(state, local_peer())
	_buttons["fine"].disabled = not (mine and int(mine_row.get("skip", 0)) > 0
		and int(mine_row.get("cash", 0)) >= TourRules.JAIL_FINE)
	# 联机时不给"重开一局"：重发只能由房主发起，客户端点了只会两边对不上
	_buttons["again"].visible = finished and _room == null

	# 所得税的二选一：两个按钮上直接写出各要交多少，让玩家一眼比出来
	var tax: Dictionary = state.get("tax", {})
	var choosing_tax := mine and phase == TourRules.Phase.DECIDING \
		and decision == TourRules.Decision.TAX
	_tax_row.visible = choosing_tax
	if choosing_tax:
		_tax_flat_button.text = tr("交固定 %d") % int(tax.get("flat", 0))
		_tax_percent_button.text = tr("按资产 %d%%（%d）") % [
			int(tax.get("percent", 10)), int(tax.get("by_percent", 0))]


func _row_of(state: Dictionary, peer_id: int) -> Dictionary:
	for row in state.get("players", []):
		if int(row["peer_id"]) == peer_id:
			return row
	return {}


func _name_of(peer_id: int) -> String:
	for entry in _players:
		if int(entry["peer_id"]) == peer_id:
			return String(entry["name"])
	return "?"


func _set_log(text: String) -> void:
	_log_label.text = text


# ---------------------------------------------------------------- 驱动

func _process(delta: float) -> void:
	# 棋子和卡片的动画是纯表现，任何时候都要推进
	_step_hop(delta)
	_step_card(delta)
	# 联机时由房间层统一 tick（两端一致）；单机这里自己推，AI 才会走。
	if _room == null and _game != null:
		_game.tick(delta)


## 棋子逐格跳：一格一跳，能看清经过了哪些格子（尤其「经过出发」）。
func _start_hop(peer_id: int, from_cell: int, to_cell: int) -> void:
	if from_cell == to_cell:
		return
	_hop = {
		"peer": peer_id,
		"from": from_cell,
		"distance": posmod(to_cell - from_cell, TourBoard.size()),
		"elapsed": 0.0,
	}


func _step_hop(delta: float) -> void:
	if _hop.is_empty() or _board == null:
		return
	_hop["elapsed"] = float(_hop["elapsed"]) + delta
	var t := clampf(float(_hop["elapsed"]) / HOP_TIME, 0.0, 1.0)
	_board.set_moving(int(_hop["peer"]),
		float(_hop["from"]) + float(_hop["distance"]) * t)
	if t >= 1.0:
		_board.clear_moving()
		_hop.clear()


## 抽卡动画。它只影响画面，卡片效果规则那边早就结算完了。
func _step_card(delta: float) -> void:
	if _card_t < 0.0 or _board == null or _game == null:
		return
	_card_t += delta
	var card: Dictionary = _game.state().get("card", {})
	_board.set_card_anim(String(card.get("text", "")), bool(card.get("chance", false)),
		clampf(_card_t / CARD_TIME, 0.0, 1.0))
	if _card_t >= CARD_TIME:
		_card_t = -1.0
		_board.clear_card_anim()


func _show_dice(dice: Array) -> void:
	if dice.size() != 2:
		return
	_dice_label.text = tr("　骰子 %d + %d = %d") % [
		int(dice[0]), int(dice[1]), int(dice[0]) + int(dice[1])]


# ---------------------------------------------------------------- 输入

## 所有操作都走这里：联机交给房间层转给房主，单机直接本地进规则。
## 界面自己不判断合法性——被拒的话房主会把原因写进日志。
func _submit(payload: PackedByteArray) -> void:
	if _game != null:
		_game.submit(payload)


func _on_roll() -> void:
	_submit(TourMessages.encode_roll())


func _on_buy() -> void:
	_submit(TourMessages.encode_buy())


func _on_upgrade() -> void:
	_submit(TourMessages.encode_upgrade())


func _on_decline() -> void:
	_submit(TourMessages.encode_decline())


func _on_pay_fine() -> void:
	_submit(TourMessages.encode_pay_fine())


func _on_tax_flat() -> void:
	_submit(TourMessages.encode_tax_flat())


func _on_tax_percent() -> void:
	_submit(TourMessages.encode_tax_percent())


## 点格子看详情。格子上只有一个短名，地价和过路费得点开才知道——
## 这是竖屏省空间的代价，用一次点击换回来。
func _on_cell_tapped(cell: int) -> void:
	var state := _game.state() if _game != null else {}
	var parts := PackedStringArray([TourBoard.name_of(cell)])
	if not TourBoard.is_purchasable(cell):
		_set_log("　".join(parts))
		return
	parts.append(tr("地价 %d") % TourBoard.price_of(cell))
	var owner := int(state.get("owner", {}).get(cell, 0))
	if owner == 0:
		parts.append(tr("无主"))
	else:
		parts.append(tr("业主 %s") % _name_of(owner))
		parts.append(tr("%d 级") % int(state.get("level", {}).get(cell, 1)))
		parts.append(tr("过路费 %d") % int(state.get("rent", {}).get(cell, 0)))
	_set_log("　".join(parts))
