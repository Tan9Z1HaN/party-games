extends Control

## 《环游中国》牌桌。目前是**单机对电脑**的形态。
##
## 大富翁是轮流制，所以单机只能是"一个真人 + 若干 AI"：同屏热座会让
## 后面的人看见前面的人的钱和地，而且一台手机传着玩太慢。
##
## 数据来源只有一个：`_rules.snapshot()`。棋盘和面板都只认那份字典——
## 联机时换成长机发来的同一份结构就行，界面一行都不用改。

signal exit_requested

const LOCAL_PEER := 1
const MAX_AI := 4               ## 一台手机上最多几个电脑对手
const AI_DELAY := 0.7           ## AI 每步之间停一下，太快看不清发生了什么
const HOP_TIME := 0.35          ## 棋子逐格跳的总时长
const CARD_TIME := 1.5          ## 抽卡动画的总时长

var _rules: TourRules
var _players: Array = []        ## [{peer_id, name, is_ai}]
var _board: TourBoardView
var _bar: HBoxContainer
var _round_label: Label
var _log_label: Label
var _dice_label: Label
var _buttons := {}
var _tax_row: HBoxContainer
var _tax_flat_button: Button
var _tax_percent_button: Button

var _ai_timer := 0.0
var _busy := false
## 逐格跳动的动画：{peer_id, from, to, elapsed}
var _hop := {}
var _last_steps := 0
var _card_t := -1.0             ## 抽卡动画的进度，负值表示没在放
var _card_seq := -1             ## 已经放过的卡号，用来发现"又来了一张新的"


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = LightTheme.build()
	add_child(LightTheme.backdrop())
	_build_ui()


# ---------------------------------------------------------------- 开局

func setup_solo(ai_count := 2) -> void:
	var count := clampi(ai_count, 1, MAX_AI)
	var names := ["小红", "小蓝", "小绿", "小黄"]
	_players = [{"peer_id": LOCAL_PEER, "name": tr("你"), "is_ai": false}]
	for i in count:
		_players.append({
			"peer_id": LOCAL_PEER + i + 1,
			"name": names[i],
			"is_ai": true,
		})

	_rules = TourRules.new()
	# 不传 max_rounds：默认不限，结束靠破产（见 rules.gd 顶部）
	_rules.setup(_players, {}, 0)
	_ai_timer = 0.0
	_busy = false
	_hop.clear()
	_last_steps = 0
	_card_t = -1.0
	_card_seq = -1
	_refresh()


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

	# 中间：棋盘。它自己撑成正方形（宽高取小的那个）
	_board = TourBoardView.new()
	_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board.cell_tapped.connect(_on_cell_tapped)
	box.add_child(_board)

	_log_label = LightTheme.label("", 28)
	_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log_label.custom_minimum_size = Vector2(0, 76)
	box.add_child(_log_label)

	# 按钮分两排：上面是当前这一步能做的动作，下面是随时可点的杂项。
	# 挤成一排的话，六个按钮每人才 160 像素，中文两三个字就顶满了。
	# 所得税的二选一单独占一排：它只在落到所得税上时出现，
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

	_add_button_row(box, [
		{"id": "roll", "text": tr("掷骰"), "call": _on_roll},
		{"id": "buy", "text": tr("买下"), "call": _on_buy},
		{"id": "upgrade", "text": tr("升级"), "call": _on_upgrade},
		{"id": "decline", "text": tr("放弃"), "call": _on_decline},
	])
	_add_button_row(box, [
		{"id": "fine", "text": tr("交罚款"), "call": _on_pay_fine},
		{"id": "again", "text": tr("重开一局"), "call": func(): setup_solo(MAX_AI)},
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


# ---------------------------------------------------------------- 刷新

func _refresh() -> void:
	if _rules == null:
		return
	var state := _rules.snapshot()
	state["hint"] = _hint_for(state)
	# 抽到新卡就放动画。靠序号判断，不靠对比文案——同一条文案可能连着抽到。
	if int(state.get("card_seq", 0)) != _card_seq:
		_card_seq = int(state.get("card_seq", 0))
		if not (state.get("card", {}) as Dictionary).is_empty():
			_card_t = 0.0
	_refresh_bar(state)
	_board.apply(state)
	_board.selected_cell = -1
	# 胜利条件是搞破产，没有总轮数可显示；改成报"还剩几个人"
	_round_label.text = tr("第 %d 轮　还剩 %d 人") % [
		int(state.get("round", 1)), int(state.get("alive", 0))]
	_log_label.text = String(state.get("log", ""))
	_refresh_buttons(state)


## 棋盘中央那行提示：告诉玩家现在该干什么。
## 状态行只说"轮到谁"，这里要说"要你做什么"。
func _hint_for(state: Dictionary) -> String:
	if bool(state.get("finished", false)):
		var winner := _rules.winner()
		return tr("%s 赢了！") % _name_of(winner)
	var current := int(state.get("current", 0))
	if current != LOCAL_PEER:
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
			return ""
	if _rules.skip_of(LOCAL_PEER) > 0:
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
	var mine := int(state.get("current", 0)) == LOCAL_PEER and not _busy
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
	_buttons["fine"].disabled = not (mine and _rules.skip_of(LOCAL_PEER) > 0
		and _rules.cash_of(LOCAL_PEER) >= TourRules.JAIL_FINE)
	_buttons["again"].visible = finished

	# 所得税的二选一：两个按钮上直接写出各要交多少，让玩家一眼比出来
	var tax: Dictionary = state.get("tax", {})
	var choosing_tax := mine and phase == TourRules.Phase.DECIDING \
		and decision == TourRules.Decision.TAX
	_tax_row.visible = choosing_tax
	if choosing_tax:
		_tax_flat_button.text = tr("交固定 %d") % int(tax.get("flat", 0))
		_tax_percent_button.text = tr("按资产 %d%%（%d）") % [
			int(tax.get("percent", 10)), int(tax.get("by_percent", 0))]


# ---------------------------------------------------------------- 驱动

func _process(delta: float) -> void:
	_step_hop(delta)
	_step_card(delta)
	if _rules == null or _rules.is_finished() or _busy:
		return

	var current := _rules.current_player()
	if _is_ai(current):
		_ai_timer += delta
		if _ai_timer < AI_DELAY:
			return
		_ai_timer = 0.0
		_act_ai(current)
		return

	# 轮到真人：如果卡在"要不要买"上，界面已经在等按钮了
	_ai_timer = 0.0


## 抽卡动画。它只影响画面，卡片效果规则那边早就结算完了。
func _step_card(delta: float) -> void:
	if _card_t < 0.0 or _board == null:
		return
	_card_t += delta
	var card: Dictionary = _rules.snapshot().get("card", {})
	_board.set_card_anim(String(card.get("text", "")), bool(card.get("chance", false)),
		clampf(_card_t / CARD_TIME, 0.0, 1.0))
	if _card_t >= CARD_TIME:
		_card_t = -1.0
		_board.clear_card_anim()


func _is_ai(peer_id: int) -> bool:
	for entry in _players:
		if int(entry["peer_id"]) == peer_id:
			return bool(entry["is_ai"])
	return false


func _act_ai(peer_id: int) -> void:
	var before_pos := _rules.pos_of(peer_id)
	var res := TourAi.act(_rules, peer_id)
	_after_action(peer_id, before_pos, res)


## 一次动作之后的收尾：放动画、刷新。
func _after_action(peer_id: int, before_pos: int, res: Dictionary) -> void:
	if bool(res.get("skipped", false)):
		_set_log(tr("%s 在滞留区待了一回合") % _name_of(peer_id))
	elif res.has("dice"):
		_last_steps = int(res.get("steps", 0))
		_show_dice(res.get("dice", []))
		_start_hop(peer_id, before_pos, _rules.pos_of(peer_id))
	_refresh()


## 棋子逐格跳：一格一跳，能看清经过了哪些格子（尤其「经过出发」）。
func _start_hop(peer_id: int, from_cell: int, to_cell: int) -> void:
	if from_cell == to_cell:
		return
	var distance := posmod(to_cell - from_cell, TourBoard.size())
	_hop = {"peer": peer_id, "from": from_cell, "distance": distance, "elapsed": 0.0}


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


func _show_dice(dice: Array) -> void:
	if dice.size() != 2:
		return
	_dice_label.text = tr("　骰子 %d + %d = %d") % [
		int(dice[0]), int(dice[1]), int(dice[0]) + int(dice[1])]


func _name_of(peer_id: int) -> String:
	for entry in _players:
		if int(entry["peer_id"]) == peer_id:
			return String(entry["name"])
	return "?"


func _set_log(text: String) -> void:
	_log_label.text = text


# ---------------------------------------------------------------- 输入

func _on_roll() -> void:
	if _rules == null or _rules.current_player() != LOCAL_PEER:
		return
	var before := _rules.pos_of(LOCAL_PEER)
	var res := _rules.roll(LOCAL_PEER)
	if not bool(res.get("ok", false)):
		_set_log(tr("不能掷骰：%s") % String(res.get("error", "")))
		return
	_after_action(LOCAL_PEER, before, res)


func _on_buy() -> void:
	var res := _rules.buy(LOCAL_PEER)
	_after_action(LOCAL_PEER, _rules.pos_of(LOCAL_PEER), res)


func _on_upgrade() -> void:
	var res := _rules.upgrade(LOCAL_PEER)
	_after_action(LOCAL_PEER, _rules.pos_of(LOCAL_PEER), res)


func _on_decline() -> void:
	_rules.decline(LOCAL_PEER)
	_refresh()


## 点格子看详情。格子上只有一个短名，地价和过路费得点开才知道——
## 这是竖屏省空间的代价，用一次点击换回来。
func _on_cell_tapped(cell: int) -> void:
	var parts := PackedStringArray([TourBoard.name_of(cell)])
	if not TourBoard.is_purchasable(cell):
		_set_log("　".join(parts))
		return
	parts.append(tr("地价 %d") % TourBoard.price_of(cell))
	var owner := _rules.owner_of(cell)
	if owner == 0:
		parts.append(tr("无主"))
	else:
		parts.append(tr("业主 %s") % _name_of(owner))
		parts.append(tr("%d 级") % _rules.level_of(cell))
		parts.append(tr("过路费 %d") % _rules.rent_at(cell))
	_set_log("　".join(parts))


func _on_pay_fine() -> void:
	var res := _rules.pay_fine(LOCAL_PEER)
	if not bool(res.get("ok", false)):
		_set_log(tr("不能交罚款：%s") % String(res.get("error", "")))
		return
	_refresh()


func _on_tax_flat() -> void:
	_rules.pay_tax_flat(LOCAL_PEER)
	_refresh()


func _on_tax_percent() -> void:
	_rules.pay_tax_percent(LOCAL_PEER)
	_refresh()
