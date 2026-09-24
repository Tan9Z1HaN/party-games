extends Control

## UNO 牌桌。目前是**单机对电脑**的形态。
##
## 为什么单机是对电脑而不是同屏热座：UNO 的核心就是隐藏手牌，
## 一台设备传着玩会让所有人看到彼此的手牌，规则直接失效。
## 所以单机模式 = 一个真人 + 若干 AI，这也顺便给以后的掉线托管铺路。
##
## 伪 3D 的说明见 ui/card_2d.gd：靠 Node2D 的 scale/skew/rotation 三件套，
## 全程 2D，没有相机也没有光照。

signal exit_requested

const LOCAL_PEER := 1
const AI_DELAY := 0.85          ## AI 每步之间的停顿，太快看不清它在干什么
const FLY_TIME := 0.34          ## 出牌飞行的时长

## 扇形手感参数，和 card_2d.gd 里的 set_fan_pose 是一套
const FAN := {"spread": 0.052, "spacing": 92.0, "arc": 12.0, "lean": 0.11}

var _rules: UnoRules
var _players: Array = []        ## [{peer_id, name, is_ai}]
var _cards_root: Node2D
var _hand_cards: Array = []     ## 我自己的手牌，UnoCard2D 数组，和 _hand_order 对应
var _hand_order: Array[int] = []
var _selected := -1
var _pile_card: UnoCard2D
var _deck_card: UnoCard2D
var _ai_timer := 0.0
var _busy := false              ## 飞行动画期间不接受输入

var _status_label: Label
var _counts_label: Label
var _color_label: Label
var _direction_label: Label
var _color_picker: PanelContainer
var _log_label: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = LightTheme.build()
	add_child(LightTheme.backdrop())

	_cards_root = Node2D.new()
	add_child(_cards_root)

	_build_ui()
	resized.connect(_layout)


func setup_solo(ai_count := 2) -> void:
	_players = [{"peer_id": LOCAL_PEER, "name": tr("你"), "is_ai": false}]
	var names := [tr("小红"), tr("小蓝"), tr("小绿")]
	for i in clamp(ai_count, 1, 3):
		_players.append({
			"peer_id": LOCAL_PEER + i + 1,
			"name": names[i],
			"is_ai": true,
		})

	var seed_value := int(Time.get_unix_time_from_system()) % 100000
	_rules = UnoRules.new()
	_rules.setup(_players, {}, seed_value)

	_sync_hand()
	_layout()
	_refresh()


# ---------------------------------------------------------------- 界面

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 36)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(box)

	_counts_label = LightTheme.label("", 30)
	box.add_child(_counts_label)

	_status_label = LightTheme.label("", 36)
	box.add_child(_status_label)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(spacer)

	var mid := HBoxContainer.new()
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_child(LightTheme.label(tr("当前颜色"), 28))
	_color_label = LightTheme.label("", 28)
	mid.add_child(_color_label)
	mid.add_child(LightTheme.label("    ", 28))
	_direction_label = LightTheme.label("", 28)
	mid.add_child(_direction_label)
	box.add_child(mid)

	_log_label = LightTheme.label("", 26)
	box.add_child(_log_label)

	var spacer2 := Control.new()
	spacer2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(spacer2)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	var uno_button := LightTheme.button(tr("喊 UNO"), 30)
	uno_button.pressed.connect(_on_say_uno)
	buttons.add_child(uno_button)
	var pass_button := LightTheme.button(tr("过牌"), 30)
	pass_button.pressed.connect(_on_pass)
	buttons.add_child(pass_button)
	var again := LightTheme.button(tr("重开一局"), 30)
	again.pressed.connect(func(): setup_solo(_players.size() - 1))
	buttons.add_child(again)
	var back := LightTheme.button(tr("退出"), 30)
	back.pressed.connect(func(): exit_requested.emit())
	buttons.add_child(back)
	box.add_child(buttons)

	_build_color_picker()


func _build_color_picker() -> void:
	_color_picker = PanelContainer.new()
	_color_picker.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := LightTheme.panel_style()
	style.bg_color = Color(0.1, 0.1, 0.15, 0.55)
	_color_picker.add_theme_stylebox_override("panel", style)
	_color_picker.visible = false
	add_child(_color_picker)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 18)
	box.add_child(LightTheme.label(tr("选一个颜色"), 44))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	for color in [UnoDeck.C.RED, UnoDeck.C.YELLOW, UnoDeck.C.GREEN, UnoDeck.C.BLUE]:
		var pick := LightTheme.button(UnoDeck.COLOR_NAMES[color], 34)
		pick.custom_minimum_size = Vector2(150, 110)
		pick.add_theme_color_override("font_color", Color(0.1, 0.1, 0.12))
		var style_box := LightTheme.surface_box(UnoCard2D.COLOR_FILL[color])
		for state in ["normal", "hover", "pressed"]:
			pick.add_theme_stylebox_override(state, style_box)
		pick.pressed.connect(func(): _on_color_chosen(color))
		row.add_child(pick)
	box.add_child(row)
	_color_picker.add_child(box)


# ---------------------------------------------------------------- 布局

func _layout() -> void:
	var view := size
	if view.x <= 0.0:
		view = Vector2(1080, 1920)

	# 弃牌堆和牌堆摆在中间偏上
	var pile_pos := Vector2(view.x * 0.42, view.y * 0.46)
	var deck_pos := Vector2(view.x * 0.66, view.y * 0.46)
	if _pile_card == null:
		_pile_card = UnoCard2D.new()
		_cards_root.add_child(_pile_card)
	if _deck_card == null:
		_deck_card = UnoCard2D.new()
		_cards_root.add_child(_deck_card)

	# 弃牌堆微微斜着放，比正着摆更有"摊在桌上"的感觉
	_pile_card.position = pile_pos
	_pile_card.rotation = -0.10
	_pile_card.scale = Vector2(1.08, 1.08 - 0.06)
	_pile_card.skew = -0.06
	_pile_card.z_index = 5

	_deck_card.set_card(0, false)
	_deck_card.position = deck_pos
	_deck_card.rotation = 0.08
	_deck_card.scale = Vector2(1.05, 1.05 - 0.05)
	_deck_card.skew = 0.05
	_deck_card.z_index = 4

	_layout_hand()


func _layout_hand() -> void:
	var view := size
	if view.x <= 0.0:
		view = Vector2(1080, 1920)
	var count := _hand_cards.size()
	if count == 0:
		return

	# 牌多了就压缩间距，别铺出屏幕
	var cfg := FAN.duplicate()
	var max_span := view.x - 260.0
	cfg["spacing"] = minf(float(FAN["spacing"]), max_span / maxf(1.0, float(count - 1)))

	var base := Vector2(view.x * 0.5, view.y - 190.0)
	for i in count:
		var card: UnoCard2D = _hand_cards[i]
		var offset := float(i) - float(count - 1) * 0.5
		card.set_fan_pose(offset, cfg)
		card.position += base
		card.snap_to_pose()
		card.position += Vector2.ZERO
		# set_fan_pose 设的是相对位置，这里整体平移到牌桌底部
		card.position = base + Vector2(offset * float(cfg["spacing"]),
			absf(offset) * float(cfg["arc"]))
		card.set_lifted(i == _selected)


# ---------------------------------------------------------------- 刷新

## 把手牌同步成引擎里的样子。发牌、出牌、摸牌之后都要调用。
func _sync_hand() -> void:
	var hand := _rules.hand_of(LOCAL_PEER)
	# 已有的卡牌节点尽量复用，只补差量，免得每次都重建导致动画被打断
	while _hand_cards.size() > hand.size():
		var extra: UnoCard2D = _hand_cards.pop_back()
		extra.queue_free()
	while _hand_cards.size() < hand.size():
		var card := UnoCard2D.new()
		_cards_root.add_child(card)
		_hand_cards.append(card)
	for i in hand.size():
		(_hand_cards[i] as UnoCard2D).set_card(hand[i], true)
	_hand_order = hand
	if _selected >= _hand_cards.size():
		_selected = -1
	_layout_hand()


func _refresh() -> void:
	if _rules == null:
		return

	# 弃牌堆顶
	_pile_card.set_card(_rules.top_card(), true)

	# 各家张数
	var parts := PackedStringArray()
	for p in _players:
		parts.append("%s %d" % [p["name"], _rules.hand_count(int(p["peer_id"]))])
	_counts_label.text = "　".join(parts)

	# 当前颜色 + 方向
	var color_index := _rules.active_color()
	_color_label.text = UnoDeck.COLOR_NAMES[color_index] if color_index >= 0 else "?"
	_color_label.add_theme_color_override("font_color",
		UnoCard2D.COLOR_FILL.get(color_index, Color.BLACK))
	_direction_label.text = tr("顺时针") if _rules.direction() > 0 else tr("逆时针")

	# 状态
	var current := _rules.current_player()
	if _rules.is_finished():
		_status_label.text = tr("%s 赢了！") % _name_of(_rules.winner())
	elif _rules.phase() == UnoRules.Phase.CHOOSING_COLOR:
		_status_label.text = tr("%s 在选颜色…") % _name_of(_rules.color_chooser())
	elif current == LOCAL_PEER:
		var hint := tr("轮到你了")
		if _rules.pending_draw() > 0:
			hint += tr("　（要摸 %d 张，或者叠牌）") % _rules.pending_draw()
		_status_label.text = hint
	else:
		_status_label.text = tr("%s 的回合…") % _name_of(current)

	_color_picker.visible = _rules.phase() == UnoRules.Phase.CHOOSING_COLOR \
		and _rules.color_chooser() == LOCAL_PEER

	_layout_hand()


func _name_of(peer_id: int) -> String:
	for p in _players:
		if int(p["peer_id"]) == peer_id:
			return String(p["name"])
	return "?"


func _set_log(text: String) -> void:
	_log_label.text = text


# ---------------------------------------------------------------- 回合驱动

func _process(delta: float) -> void:
	if _rules == null or _rules.is_finished() or _busy:
		return
	var current := _rules.current_player()
	if current == LOCAL_PEER:
		_ai_timer = 0.0
		return
	# AI 每步之间停一下，不然一瞬间打完根本看不清发生了什么
	_ai_timer += delta
	if _ai_timer >= AI_DELAY:
		_ai_timer = 0.0
		_ai_step()


func _ai_step() -> void:
	var peer := _rules.current_player()

	if _rules.phase() == UnoRules.Phase.CHOOSING_COLOR:
		_rules.choose_color(peer, UnoAi.choose_color(_rules, peer))
		_refresh()
		return

	var card := UnoAi.choose_card(_rules, peer)
	if card >= 0:
		_play(peer, card)
		return

	# 没牌可出就摸。摸到的能出就出，不能出则过（auto_pass 开着的话引擎已自动过）
	var drew := _rules.draw_card(peer)
	if bool(drew.get("playable", false)):
		var again := UnoAi.choose_card(_rules, peer)
		if again >= 0:
			_play(peer, again)
			return
	if _rules.current_player() == peer:
		_rules.pass_turn(peer)
	_set_log(tr("%s 摸了一张") % _name_of(peer))
	_sync_hand()
	_refresh()


## 出牌的统一入口。真人点和 AI 都走这里，动画路径一致。
func _play(peer: int, card: int) -> void:
	var from_pos := _source_position(peer, card)

	if UnoDeck.is_wild(card):
		var res := _rules.play_card(peer, card)
		if bool(res.get("needs_color", false)):
			if peer == LOCAL_PEER:
				_refresh()
				return          # 等玩家在选色面板上点
			_rules.choose_color(peer, UnoAi.choose_color(_rules, peer))
	else:
		_rules.play_card(peer, card)

	_set_log(tr("%s 出了 %s") % [_name_of(peer), UnoDeck.describe(card)])
	_animate_play(card, from_pos, peer)


## 算出「这张牌是从哪飞出来的」，用来做起飞点。
func _source_position(peer: int, card: int) -> Vector2:
	if peer == LOCAL_PEER:
		var index := _hand_order.find(card)
		if index >= 0 and index < _hand_cards.size():
			return (_hand_cards[index] as UnoCard2D).position
		return Vector2(size.x * 0.5, size.y - 190.0)
	# 对手：从他名字那一行附近飞出来
	for i in _players.size():
		if int(_players[i]["peer_id"]) == peer:
			var t := float(i) / maxf(1.0, float(_players.size() - 1))
			return Vector2(size.x * (0.2 + t * 0.6), 150.0)
	return Vector2(size.x * 0.5, 150.0)


## 出一张牌的飞行动画：从起飞点滑到弃牌堆，姿态一路过渡到牌堆的斜放。
## 这是「牌的移动」最值得做的一处——不做的话牌是瞬移的，很出戏。
func _animate_play(card: int, from_pos: Vector2, peer: int) -> void:
	_busy = true
	var flying := UnoCard2D.new()
	flying.set_card(card, true)
	flying.position = from_pos
	flying.z_index = 80
	flying.rotation = -0.25
	flying.skew = 0.25
	_cards_root.add_child(flying)

	_sync_hand()
	_refresh()

	var tween := create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(flying, "position", _pile_card.position, FLY_TIME)
	tween.tween_property(flying, "rotation", _pile_card.rotation, FLY_TIME)
	tween.tween_property(flying, "skew", _pile_card.skew, FLY_TIME)
	tween.tween_property(flying, "scale", _pile_card.scale, FLY_TIME)
	tween.chain().tween_callback(func():
		flying.queue_free()
		_busy = false
		_refresh()
		# 玩家出了万能牌、或者轮到玩家选色，就把选色面板亮出来
		if _rules.phase() == UnoRules.Phase.CHOOSING_COLOR \
				and _rules.color_chooser() == LOCAL_PEER:
			_color_picker.visible = true)


# ---------------------------------------------------------------- 输入

func _gui_input(event: InputEvent) -> void:
	if _rules == null or _busy or _color_picker.visible:
		return
	if _rules.current_player() != LOCAL_PEER:
		return
	if _rules.phase() != UnoRules.Phase.PLAYING:
		return

	var pressed := false
	var pos := Vector2.ZERO
	if event is InputEventScreenTouch:
		pressed = event.pressed
		pos = event.position
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		pressed = event.pressed
		pos = event.position
	if not pressed:
		return

	var index := _pick_card(pos)
	if index < 0:
		_selected = -1
		_layout_hand()
		return

	if _selected == index:
		_try_play_hand_card(index)
	else:
		_selected = index
		_layout_hand()


## 命中测试。牌有旋转和错切，精确判定不划算——
## 扇形展开的角度很小，用未变换的矩形够用。
func _pick_card(local_pos: Vector2) -> int:
	var half := UnoCard2D.SIZE * 0.5
	# 从上层往下找，压在上面的先被点到
	for i in range(_hand_cards.size() - 1, -1, -1):
		var card: UnoCard2D = _hand_cards[i]
		var d := local_pos - card.position
		if absf(d.x) <= half.x and absf(d.y) <= half.y:
			return i
	return -1


func _try_play_hand_card(index: int) -> void:
	var card := _hand_order[index]
	if not _rules.can_play(LOCAL_PEER, card):
		_set_log(tr("这张现在出不了"))
		_selected = -1
		_layout_hand()
		return
	_selected = -1
	_play(LOCAL_PEER, card)


func _on_color_chosen(color: int) -> void:
	_color_picker.visible = false
	_rules.choose_color(LOCAL_PEER, color)
	_set_log(tr("你把颜色定成了 %s") % UnoDeck.COLOR_NAMES[color])
	_animate_play(_rules.top_card(), _pile_card.position, LOCAL_PEER)


func _on_say_uno() -> void:
	var res := _rules.say_uno(LOCAL_PEER)
	_set_log(tr("你喊了 UNO！") if res.get("ok", false) else tr("现在不用喊") )
	_refresh()


func _on_pass() -> void:
	var res := _rules.pass_turn(LOCAL_PEER)
	if not res.get("ok", false):
		_set_log(tr("没摸牌就不能过"))
		return
	_set_log(tr("你过牌"))
	_sync_hand()
	_refresh()
