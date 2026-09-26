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
## 逐格跳动的节奏**按格数算，不是一个固定总时长**：固定总时长的话，
## 走 1 格和走 12 格一样慢，短步拖沓、长步又看不清跳过了哪些格。
const HOP_STEP_TIME := 0.075    ## 每跳一格用多久
const HOP_MIN_TIME := 0.20      ## 但至少这么久——一格也得看得见
const HOP_MAX_TIME := 0.90      ## 最多这么久，12 格不能再长了
const CARD_TIME := 1.8          ## 抽卡动画的总时长（点一下可以跳过）
const DICE_ROLL_TIME := 0.45    ## 骰子摇动的时间
const FLASH_TIME := 0.7         ## 落地那一格亮多久
const CASH_FLASH_TIME := 1.4    ## 顶栏上「+200 / -150」挂多久

var _game: TourGame
var _room: Room = null
var _players: Array = []
var _ai_count := 2              ## 单机开几个电脑，重开一局按这个来
var _board: TourBoardView
## 用 HFlowContainer 而不是 HBox：6 个人再加上「+200」飘字，
## 一行排不下——HBox 不会换行，最后那个人会被直接切掉。
var _bar: HFlowContainer
var _round_label: Label
var _log_label: Label
var _dice_label: Label
var _buttons := {}
var _tax_row: HBoxContainer
var _tax_flat_button: Button
var _tax_percent_button: Button
var _result_layer: CenterContainer
var _result_title: Label
var _result_sub: Label
var _result_rows: VBoxContainer
var _result_again: Button

var _busy := false
## 逐格跳动的动画：{peer, from, steps, elapsed, total}
var _hop := {}
var _card_t := -1.0             ## 抽卡动画的进度，负值表示没在放
var _card_seq := -1             ## 已经放过的卡号，用来发现「又来了一张新的」
var _card_tapped := false       ## 刚用「点一下」跳过抽卡，那一下不算点格子
var _dice_t := -1.0             ## 骰子摇动的进度，负值表示没在摇
var _dice_value := []           ## 摇完之后要显示的真实点数
var _flash := {}                ## 落地高亮：{cell, t}
var _cash_flash := {}           ## peer -> {delta, t}，顶栏上的收付飘字
## 上一次看到的状态，用来发现「谁动了」「骰子换了」——单机和联机都靠它，
## 这样动画逻辑只有一份，不用管状态是本地算的还是网络送来的。
var _prev_pos := {}
var _prev_dice := []
var _prev_cash := {}
var _result_shown := false      ## 结算面板已经弹过（玩家手动收掉之后别再弹）


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = LightTheme.build()
	add_child(LightTheme.backdrop())
	_build_ui()


# ---------------------------------------------------------------- 开局

func setup_solo(ai_count := 2) -> void:
	var count := clampi(ai_count, 1, MAX_AI)
	_ai_count = count
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
	_card_tapped = false
	_dice_t = -1.0
	_dice_value = []
	_flash.clear()
	_cash_flash.clear()
	_prev_pos.clear()
	_prev_dice = []
	_prev_cash.clear()
	_result_shown = false
	if _result_layer != null:
		_result_layer.visible = false
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
	_bar = HFlowContainer.new()
	_bar.add_theme_constant_override("h_separation", 16)
	_bar.add_theme_constant_override("v_separation", 4)
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
	_board.tapped_anywhere.connect(_on_board_tapped)
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

	_build_result_panel()


## 结算面板：打完一局盖在棋盘上，把资产排名摊开。
##
## 之前只在状态行写一句「谁赢了」——一局十几分钟，打完就一行小字，
## 是整局观感上最亏的地方。排名里连现金和资产一起给，输的人才看得出输在哪。
func _build_result_panel() -> void:
	_result_layer = CenterContainer.new()
	_result_layer.name = "ResultLayer"
	_result_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 盖住整屏：面板在的时候不该还能点到棋盘底下的按钮
	_result_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	_result_layer.visible = false
	add_child(_result_layer)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
		LightTheme.surface_box(LightTheme.SURFACE))
	_result_layer.add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	panel.add_child(col)

	_result_title = LightTheme.label("", 44)
	_result_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_result_title)

	_result_sub = LightTheme.label("", 30)
	_result_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_result_sub)

	_result_rows = VBoxContainer.new()
	_result_rows.add_theme_constant_override("separation", 10)
	col.add_child(_result_rows)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	col.add_child(row)

	var look := LightTheme.button(tr("看棋盘"), 30)
	look.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	look.pressed.connect(func(): _result_layer.visible = false)
	row.add_child(look)

	# 联机时不给"再来一局"：重发只能房主发起，客户端点了只会两边对不上
	_result_again = LightTheme.button(tr("再来一局"), 30)
	_result_again.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_result_again.pressed.connect(_on_again)
	row.add_child(_result_again)


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
	setup_solo(_ai_count)


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
	_update_result(state)


## 从状态的变化里发现「有人动了」「骰子换了」「抽到新卡了」，然后放动画。
##
## 靠**对比前后两份状态**，而不是靠事件回调：单机时状态是本地算的，
## 联机时是每 0.25 秒送来的，对比出来一模一样，动画逻辑就只有一份。
func _catch_up_animations(state: Dictionary) -> void:
	for row in state.get("players", []):
		var peer := int(row["peer_id"])
		var pos := int(row["pos"])
		# 钱的变化也要认出来：顶栏上挂一下「+200 / -150」，
		# 不然一局里钱什么时候变的、变了多少，全靠盯数字
		var cash := int(row["cash"])
		# 出局的人不挂飘字：破产时现金被清 0，飘出来的是「-600」这种
		# 看着像"又付了一大笔"的假数字，而顶栏已经写着"出局"了
		if not bool(row["out"]) and _prev_cash.has(peer) and int(_prev_cash[peer]) != cash:
			_flash_cash(peer, cash - int(_prev_cash[peer]))
		_prev_cash[peer] = cash
		if bool(row["out"]):
			_prev_pos.erase(peer)
			continue
		if _prev_pos.has(peer) and int(_prev_pos[peer]) != pos:
			_start_hop(peer, int(_prev_pos[peer]), pos)
		_prev_pos[peer] = pos

	var dice: Array = state.get("dice", [])
	if dice.size() == 2 and str(dice) != str(_prev_dice):
		_prev_dice = dice.duplicate()
		# 先摇一会儿再落定：直接蹦出点数没有"掷"的感觉
		_dice_value = dice.duplicate()
		_dice_t = 0.0
		_dice_label.text = tr("　掷骰中…")

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
		var out := bool(row["out"])
		if bool(row["out"]):
			line = "%s 出局" % String(row["name"])
		if peer == int(state.get("current", 0)):
			line = "▶ " + line
		# 一个玩家占一小块：名字和现金保持他自己的颜色（不然四个人一起收付钱，
		# 顶栏全是红的绿的，谁也认不出谁是谁），飘字单独一个颜色挂后面。
		var chip := HBoxContainer.new()
		chip.add_theme_constant_override("separation", 6)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var who := LightTheme.label(line, 26)
		who.add_theme_color_override("font_color",
			Color(0.6, 0.6, 0.62) if out else _board.color_of(peer))
		chip.add_child(who)
		var flash: Dictionary = _cash_flash.get(peer, {})
		if not flash.is_empty():
			var delta := int(flash["delta"])
			# 正的带 +，负的本身就带 -，别写成 "+-150"
			var tag := LightTheme.label(("+%d" % delta) if delta > 0 else ("%d" % delta), 26)
			tag.add_theme_color_override("font_color",
				Color(0.09, 0.55, 0.22) if delta > 0 else Color(0.80, 0.22, 0.18))
			chip.add_child(tag)
		_bar.add_child(chip)


func _flash_cash(peer_id: int, delta: int) -> void:
	if delta == 0:
		return
	_cash_flash[peer_id] = {"delta": delta, "t": CASH_FLASH_TIME}


# ---------------------------------------------------------------- 结算

## 名次表：活着的人排前面（资产高的在前），出局的排后面。
##
## 不直接按 assets 排：出局的人资产都是 0，而"活着但两手空空"的人
## 资产也是 0，按资产排会把活着的人排到出局的人后面——那不合直觉。
func _standings(state: Dictionary) -> Array:
	var rows: Array = []
	for row in state.get("players", []):
		rows.append(row)
	rows.sort_custom(func(a, b):
		if bool(a["out"]) != bool(b["out"]):
			return not bool(a["out"])
		return int(a["assets"]) > int(b["assets"]))
	return rows


func _update_result(state: Dictionary) -> void:
	if _result_layer == null or not bool(state.get("finished", false)):
		return
	var rows := _standings(state)
	if rows.is_empty():
		return
	_result_title.text = tr("%s 赢了") % String(rows[0]["name"])
	_result_title.add_theme_color_override("font_color",
		_board.color_of(int(rows[0]["peer_id"])))
	_result_sub.text = _result_subtitle(rows)
	LightTheme.clear_children(_result_rows)
	for i in rows.size():
		_result_rows.add_child(_result_row(rows[i], i))
	_result_again.visible = _room == null
	# 只自动弹一次：玩家点「看棋盘」收掉之后，别再弹回来
	if not _result_shown:
		_result_shown = true
		LightTheme.present(_result_layer)


func _result_subtitle(rows: Array) -> String:
	var me := local_peer()
	for i in rows.size():
		if int(rows[i]["peer_id"]) != me:
			continue
		if i == 0:
			# 标题已经写着「你 赢了」，副标题再来一句「你赢了」就重复了
			return tr("你是唯一没破产的人")
		if bool(rows[i]["out"]):
			return tr("你第 %d 名，已出局") % (i + 1)
		return tr("你第 %d 名") % (i + 1)
	return tr("本局结束")


func _result_row(row: Dictionary, rank: int) -> Control:
	var peer := int(row["peer_id"])
	var out := bool(row["out"])
	var color := Color(0.6, 0.6, 0.62) if out else _board.color_of(peer)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 14)

	var medal := LightTheme.label(tr("%d.") % (rank + 1), 30)
	medal.add_theme_color_override("font_color", color)
	medal.custom_minimum_size = Vector2(64, 0)
	line.add_child(medal)

	var who := LightTheme.label(String(row["name"]) + (tr("（你）") if peer == local_peer() else ""), 30)
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.add_theme_color_override("font_color", color)
	line.add_child(who)

	var detail := tr("出局") if out else tr("资产 %d（现金 %d）") % [
		int(row["assets"]), int(row["cash"])]
	line.add_child(LightTheme.label(detail, 28))
	return line


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
	_step_dice(delta)
	_step_flash(delta)
	_step_cash_flash(delta)
	# 联机时由房间层统一 tick（两端一致）；单机这里自己推，AI 才会走。
	# **动画没放完就先不推**：让 AI 等棋子跳完、卡片读完再动下一步，
	# 否则一步接一步刷屏，看的人根本跟不上刚才发生了什么。
	if _room == null and _game != null and not _is_animating():
		_game.tick(delta)


func _is_animating() -> bool:
	return not _hop.is_empty() or _card_t >= 0.0 or _dice_t >= 0.0


## 棋子逐格跳：一格一跳，能看清经过了哪些格子（尤其「经过出发」）。
func _start_hop(peer_id: int, from_cell: int, to_cell: int) -> void:
	var steps := to_cell - from_cell
	# 走过头就是绕圈回来：40 格的盘上差 38 格，其实是往回走了 2 格。
	# 不管方向一律"往前绕"的话，抽到「后退 2 格」会横穿整张棋盘。
	if steps > TourBoard.size() / 2:
		steps -= TourBoard.size()
	elif steps < -TourBoard.size() / 2:
		steps += TourBoard.size()
	if steps == 0:
		return
	_hop = {
		"peer": peer_id,
		"from": from_cell,
		"steps": steps,
		"elapsed": 0.0,
		"total": clampf(absf(float(steps)) * HOP_STEP_TIME, HOP_MIN_TIME, HOP_MAX_TIME),
	}


func _step_hop(delta: float) -> void:
	if _hop.is_empty() or _board == null:
		return
	_hop["elapsed"] = float(_hop["elapsed"]) + delta
	var t := clampf(float(_hop["elapsed"]) / float(_hop["total"]), 0.0, 1.0)
	# 缓出：起步快、快落地时慢下来，比匀速自然
	var eased := 1.0 - pow(1.0 - t, 2.0)
	_board.set_moving(int(_hop["peer"]),
		float(_hop["from"]) + float(_hop["steps"]) * eased)
	if t >= 1.0:
		_flash = {
			"cell": posmod(int(_hop["from"]) + int(_hop["steps"]), TourBoard.size()),
			"t": FLASH_TIME,
		}
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
		_end_card()


func _end_card() -> void:
	_card_t = -1.0
	if _board != null:
		_board.clear_card_anim()


## 骰子摇动：前 0.45 秒画乱跳的点数，之后落回真实点数并写出总数。
func _step_dice(delta: float) -> void:
	if _dice_t < 0.0:
		return
	_dice_t += delta
	if _dice_t >= DICE_ROLL_TIME:
		_dice_t = -1.0
		_show_dice(_dice_value)
	if _board != null:
		_board.set_dice_anim(_dice_t)


## 落地那一格的高亮，衰减着收掉。
func _step_flash(delta: float) -> void:
	if _flash.is_empty():
		return
	_flash["t"] = float(_flash["t"]) - delta
	var amount := maxf(float(_flash["t"]) / FLASH_TIME, 0.0)
	if _board != null:
		_board.set_flash(int(_flash["cell"]), amount)
	if amount <= 0.0:
		_flash.clear()


## 顶栏上的收付飘字到点了就收掉，顺便把顶栏重画一遍。
func _step_cash_flash(delta: float) -> void:
	if _cash_flash.is_empty():
		return
	var expired := false
	for peer in _cash_flash.keys():
		_cash_flash[peer]["t"] = float(_cash_flash[peer]["t"]) - delta
		if float(_cash_flash[peer]["t"]) <= 0.0:
			_cash_flash.erase(peer)
			expired = true
	if expired and _game != null:
		_refresh_bar(_game.state())


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
	# 刚点掉抽卡动画的那一下不算点格子：同一个手势不该既跳卡又开详情
	if _card_tapped:
		_card_tapped = false
		return
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


## 棋盘上点任意一处。抽卡动画挡着的时候，点一下直接看完——
## 一张已经结算完的卡片让人干等 1.8 秒，太久了。
func _on_board_tapped() -> void:
	if _card_t < 0.0:
		return
	_card_tapped = true
	_end_card()
