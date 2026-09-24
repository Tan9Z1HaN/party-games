extends Control

## UNO 牌桌。目前是**单机对电脑**的形态。
##
## 为什么单机是对电脑而不是同屏热座：UNO 的核心就是隐藏手牌，
## 一台设备传着玩会让所有人看到彼此的手牌，规则直接失效。
## 所以单机模式 = 一个真人 + 若干 AI，这也顺便给以后的掉线托管铺路。
##
## 伪 3D 的说明见 ui/fake3d.gdshader 和 ui/card_2d.gd：在 canvas_item 的
## shader 里自己做透视投影，全程 2D，没有相机也没有光照。

signal exit_requested

const LOCAL_PEER := 1
const AI_DELAY := 0.85          ## AI 每步之间的停顿，太快看不清它在干什么
const FLY_TIME := 0.34          ## 出牌飞行的时长

## 手牌手感参数。和 card_2d.gd 的 set_fan_pose 对得上，
## 想调手感就改这里，改完跑 tools/tests/screenshot_matrix.gd 看图。
##
## 手牌是**平铺**的：一张挨一张横向排开，不带旋转也不带 3D 姿态。
## 扇形那一套参数在 set_fan_pose 里都留着（spread / arc / turn / tilt），
## 想让手牌带点角度只要在这里传值，不用改布局代码。
const FAN_SPACING := 92.0

## 牌桌内容的宽度上限。桌面窗口拉得很宽时把牌桌收在一条竖条里居中，
## 否则牌堆会被甩到屏幕两端、中间空一大片。
const TABLE_MAX_W := 1320.0
## 上下两条被界面占掉的带子：上面是人数和状态，下面是按钮。
const TOP_RESERVE := 150.0
const BOTTOM_RESERVE := 150.0

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

## 牌的整体缩放。跟着视口高度走，见 _layout()。
var _card_scale := 1.0
## 牌堆和牌堆左边那张牌背的中心。每次重排都重算。
var _pile_center := Vector2.ZERO
var _deck_center := Vector2.ZERO
## 每出一张牌给牌堆抖一点角度，看起来才像一张张叠上去的，而不是同一张在换图。
var _pile_tilt := 0.0

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

	# 牌面贴图是运行时烘的（见 ui/card_art.gd），第一局开局前等它一下。
	# 之后就一直命中缓存，重开一局是瞬时的。
	await UnoCardArt.ensure_baked()

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
	# 卡牌是 Node2D，z_index 在 0~90；界面控件必须压在上面，
	# 否则手牌会盖住底部的按钮（一开始就是这样，牌挡住了「重开一局」）。
	margin.z_index = 100
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
	# 也能直接点牌堆摸牌，这个按钮是给「不知道能点哪儿」的人兜底的
	var draw_button := LightTheme.button(tr("摸牌"), 30)
	draw_button.pressed.connect(_on_draw)
	buttons.add_child(draw_button)
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
	_color_picker.z_index = 200
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
		var style_box := LightTheme.surface_box(UnoCardPainter.COLOR_FILL[color])
		for state in ["normal", "hover", "pressed"]:
			pick.add_theme_stylebox_override(state, style_box)
		pick.pressed.connect(func(): _on_color_chosen(color))
		row.add_child(pick)
	box.add_child(row)
	_color_picker.add_child(box)


# ---------------------------------------------------------------- 布局

## 可用的绘制区域。窗口大小还没定下来时退回设计稿尺寸。
func view_size() -> Vector2:
	var view := size
	if view.x <= 0.0 or view.y <= 0.0:
		return Vector2(1080, 1920)
	return view


func _layout() -> void:
	var view := view_size()
	var table_w := minf(view.x, TABLE_MAX_W)

	# 牌的大小：跟着可用高度走，同时不能大到一副手牌铺不下。
	# 1080x1920 的设计稿在这里正好算出 1.0。
	var by_height := view.y / 1740.0
	# 8 张牌的横向预算：牌宽 148 + 7 个间距 92
	var by_width := table_w * 0.86 / 792.0
	_card_scale = clampf(minf(by_height, by_width), 0.55, 1.35)

	if _pile_card == null:
		_pile_card = UnoCard2D.new()
		_cards_root.add_child(_pile_card)
	if _deck_card == null:
		_deck_card = UnoCard2D.new()
		_cards_root.add_child(_deck_card)

	var card_half := UnoCard2D.SIZE.y * _card_scale * 0.5
	var hand_top := view.y - BOTTOM_RESERVE - card_half * 2.0 - 40.0
	# 牌堆摆在"顶部标题"和"手牌上沿"之间正中：屏幕多高、多宽都不会
	# 在中间留出一大片死空，也不会顶到任何一边。
	var pile_y := (TOP_RESERVE + hand_top) * 0.5
	_pile_center = Vector2(view.x * 0.5, pile_y)
	_deck_center = _pile_center + Vector2(UnoCard2D.SIZE.x * _card_scale * 1.55, 0.0)

	_place_pile()
	_place_deck()
	_layout_hand()


## 弃牌堆。稍微斜着、并且往后仰，像是摊在桌面上。
func _place_pile() -> void:
	_pile_card.place_at(_pile_center, -0.09 + _pile_tilt, 16.0, -14.0,
		_card_scale * 1.08, 5)


func _place_deck() -> void:
	_deck_card.set_card(-1, false)
	_deck_card.place_at(_deck_center, 0.08, 16.0, 12.0, _card_scale * 1.05, 4)


func _layout_hand() -> void:
	var view := view_size()
	var count := _hand_cards.size()
	if count == 0:
		return

	var card_half := UnoCard2D.SIZE.y * _card_scale * 0.5
	var max_offset := maxf(1.0, (float(count) - 1.0) * 0.5)
	var origin := Vector2(view.x * 0.5, view.y - BOTTOM_RESERVE - card_half)

	# 间距先按手感取基准值，张数多了再压，免得铺出屏幕
	var spacing := FAN_SPACING * _card_scale
	if count > 1:
		var span_budget := minf(view.x, TABLE_MAX_W) * 0.94 \
			- UnoCard2D.SIZE.x * _card_scale
		spacing = minf(spacing, span_budget / (float(count) - 1.0))

	var cfg := {
		"origin": origin,
		"spacing": spacing,
		"scale": _card_scale,
	}
	for i in count:
		var card: UnoCard2D = _hand_cards[i]
		# stack_index 用下标：右边的牌压在左边上面，跟手里真拿着一叠牌一样
		card.set_fan_pose(float(i) - max_offset, cfg, i)
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
		UnoCardPainter.COLOR_FILL.get(color_index, Color.BLACK))
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
		elif _rules.drawn_this_turn():
			hint += tr("　（出牌，或者过牌）")
		else:
			hint += tr("　（点牌堆摸牌）")
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
		return Vector2(view_size().x * 0.5, view_size().y - BOTTOM_RESERVE)
	# 对手：从他名字那一行附近飞出来
	for i in _players.size():
		if int(_players[i]["peer_id"]) == peer:
			var t := float(i) / maxf(1.0, float(_players.size() - 1))
			return Vector2(size.x * (0.2 + t * 0.6), 150.0)
	return Vector2(size.x * 0.5, 150.0)


## 出一张牌的飞行动画。两段走：
##   第一段冲到牌堆正上方，同时转正、放大 —— 像被甩出去；
##   第二段落下去，带一点回弹。
## 姿态（绕竖轴 / 横轴）也是 tween 出来的，所以牌在空中是真的在转身，
## 不是只在平面上平移。这是「牌的移动」最值得做的一处：
## 不做的话牌是瞬移的，很出戏。
func _animate_play(card: int, from_pos: Vector2, _peer: int) -> void:
	_busy = true

	# 每张牌落下的角度都不一样，牌堆才像一张张叠上去的
	_pile_tilt = randf_range(-0.10, 0.10)
	_place_pile()

	var flying := UnoCard2D.new()
	flying.set_card(card, true)
	# 起点提到手牌上方一点，视觉上是"先抽出来再飞"
	flying.place_at(from_pos + Vector2(0, -40), -0.22, 0.0, 0.0,
		_card_scale * 1.05, 80)
	_cards_root.add_child(flying)

	_sync_hand()
	_refresh()

	var target := _pile_card.position
	var apex := target + Vector2(0, -170.0)
	var fly_out := FLY_TIME * 0.45
	var fly_down := FLY_TIME * 0.55

	var up := create_tween()
	up.set_parallel(true)
	up.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	up.tween_property(flying, "position", apex, fly_out)
	up.tween_property(flying, "rotation", -0.04, fly_out)
	up.tween_property(flying, "scale", Vector2.ONE * _card_scale * 1.20, fly_out)
	up.tween_property(flying, "perspective_y", -12.0, fly_out)
	up.tween_property(flying, "perspective_x", _pile_card.perspective_x, fly_out)
	await up.finished

	var down := create_tween()
	down.set_parallel(true)
	down.set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	down.tween_property(flying, "position", target, fly_down)
	down.tween_property(flying, "rotation", _pile_card.rotation, fly_down)
	down.tween_property(flying, "scale", _pile_card.scale, fly_down)
	down.tween_property(flying, "perspective_y", _pile_card.perspective_y, fly_down)
	await down.finished

	flying.queue_free()
	_busy = false
	_refresh()
	# 玩家出了万能牌、或者轮到玩家选色，就把选色面板亮出来
	if _rules.phase() == UnoRules.Phase.CHOOSING_COLOR \
			and _rules.color_chooser() == LOCAL_PEER:
		_color_picker.visible = true


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
		# 点空处取消选择；点牌堆就是摸牌
		if _hit_deck(pos):
			_on_draw()
			return
		_selected = -1
		_layout_hand()
		return

	if _selected == index:
		_try_play_hand_card(index)
	else:
		_selected = index
		# 记下从牌的哪个位置抓起来，提起来时会朝那一角翻过去
		(_hand_cards[index] as UnoCard2D).set_grab(pos)
		_layout_hand()


## 点牌堆的判定框。比牌本身大一圈，手机上不好点准。
func _hit_deck(local_pos: Vector2) -> bool:
	var half := UnoCard2D.SIZE * 0.5 * _card_scale * 1.3
	var d := local_pos - _deck_center
	return absf(d.x) <= half.x and absf(d.y) <= half.y


## 命中测试。牌有旋转和错切，精确判定不划算——
## 扇形展开的角度很小，用未变换的矩形够用。
func _pick_card(local_pos: Vector2) -> int:
	# z_index 才是"谁压在上面"，跟数组顺序不是一回事（中间的牌压住两边的），
	# 所以取命中里面 z_index 最大的那张。
	var found := -1
	var best_z := -1000
	for i in _hand_cards.size():
		var card: UnoCard2D = _hand_cards[i]
		var half := UnoCard2D.SIZE * 0.5 * card.scale.x
		var d := local_pos - card.position
		if absf(d.x) <= half.x and absf(d.y) <= half.y and card.z_index > best_z:
			best_z = card.z_index
			found = i
	return found


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
	_animate_play(_rules.top_card(),
		Vector2(view_size().x * 0.5, view_size().y - BOTTOM_RESERVE), LOCAL_PEER)


func _on_say_uno() -> void:
	var res := _rules.say_uno(LOCAL_PEER)
	_set_log(tr("你喊了 UNO！") if res.get("ok", false) else tr("现在不用喊") )
	_refresh()


## 摸牌。入口有两个：点牌堆，或者点底部那个「摸牌」按钮。
## 规则本身管着「是不是你的回合」「本回合摸过没有」，这里只负责翻译结果。
func _on_draw() -> void:
	if _rules == null or _busy or _color_picker.visible:
		return
	var res := _rules.draw_card(LOCAL_PEER)
	if not bool(res.get("ok", false)):
		_set_log(tr("不能摸牌：%s") % String(res.get("error", "")))
		return

	var taken: Array = res.get("cards", [])
	if bool(res.get("penalty", false)):
		# 罚抽是一次摸完并直接过回合，不值得一张张飞
		_set_log(tr("吃了 %d 张罚牌") % taken.size())
		_sync_hand()
		_refresh()
		return

	_set_log(tr("你摸了一张"))
	_animate_draw()


## 摸牌的动画：一张牌背从牌堆飞进手里，落位之后才亮出牌面。
## 新牌先藏起来、等飞过来的那张落位再显示，否则会看到两张牌重叠一下。
func _animate_draw() -> void:
	_busy = true
	_sync_hand()
	_refresh()

	var landed: UnoCard2D = _hand_cards[_hand_cards.size() - 1]
	var target := landed.position
	var target_scale := landed.scale
	landed.visible = false

	var flying := UnoCard2D.new()
	flying.set_card(-1, false)
	flying.place_at(_deck_center, 0.0, _deck_card.perspective_x,
		_deck_card.perspective_y, _card_scale * 1.02, 80)
	_cards_root.add_child(flying)

	var out := create_tween()
	out.set_parallel(true)
	out.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	out.tween_property(flying, "position", target + Vector2(0, -70.0), FLY_TIME * 0.62)
	out.tween_property(flying, "scale", target_scale, FLY_TIME * 0.62)
	out.tween_property(flying, "perspective_x", 0.0, FLY_TIME * 0.62)
	out.tween_property(flying, "perspective_y", 0.0, FLY_TIME * 0.62)
	await out.finished

	var drop := create_tween()
	drop.set_parallel(true)
	drop.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	drop.tween_property(flying, "position", target, FLY_TIME * 0.38)
	await drop.finished

	flying.queue_free()
	landed.visible = true
	_busy = false
	_refresh()


func _on_pass() -> void:
	var res := _rules.pass_turn(LOCAL_PEER)
	if not res.get("ok", false):
		_set_log(tr("没摸牌就不能过"))
		return
	_set_log(tr("你过牌"))
	_sync_hand()
	_refresh()
