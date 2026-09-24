extends Control

## UNO 牌桌。**这一层是纯视图**：只认 UnoGame 给出的状态字典，
## 自己不碰规则，也不知道对面是 AI 还是网络上的真人。
##
## 为什么单机是对电脑而不是同屏热座：UNO 的核心就是隐藏手牌，
## 一台设备传着玩会让所有人看到彼此的手牌，规则直接失效。
## 所以单机模式 = 一个真人 + 若干 AI。
##
## 伪 3D 的说明见 ui/fake3d.gdshader 和 ui/card_2d.gd：在 canvas_item 的
## shader 里自己做透视投影，全程 2D，没有相机也没有光照。
##
## 数据流：输入只走 _game.submit(报文)；状态只从 _game.state() 读。
## 单机时 submit 直接在本地进规则，联机时由房间层转给房主——
## 界面这一层完全不用分叉。

signal exit_requested

const FLY_TIME := 0.34          ## 出牌飞行的时长

## 单机时本机的 peer id。联机时用房间分配的真实 id。
const SOLO_PEER := 1

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

var _game: UnoGame
var _room: Room = null
var _players: Array = []        ## 从状态字典里读出来的 [{peer_id, name, count}]
var _cards_root: Node2D
var _hand_cards: Array = []     ## 我自己的手牌，UnoCard2D 数组，和 _hand_order 对应
var _hand_order: Array[int] = []
var _selected := -1
var _pile_card: UnoCard2D
var _deck_card: UnoCard2D
var _busy := false              ## 飞行动画期间不接受输入
## 本机出牌时的那张牌原来在哪，用来做起飞点。
## 事件是权威端处理完之后才回来的，那时牌已经从手牌里删掉了，所以要提前记。
var _play_from := Vector2.ZERO
var _has_play_from := false

## 牌的整体缩放。跟着视口高度走，见 _layout()。
var _card_scale := 1.0
## 牌堆和牌堆左边那张牌背的中心。每次重排都重算。
var _pile_center := Vector2.ZERO
var _deck_center := Vector2.ZERO
## 每出一张牌给牌堆抖一点角度，看起来才像一张张叠上去的，而不是同一张在换图。
var _pile_tilt := 0.0
## 状态字典里的局号。变了说明是新的一局，手牌节点要全清。
var _round := -1
## 单机重开时沿用的人数
var _solo_ai_count := 2

var _status_label: Label
var _counts_label: Label
var _color_label: Label
var _direction_label: Label
var _color_picker: PanelContainer
var _log_label: Label
var _again_button: Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = LightTheme.build()
	add_child(LightTheme.backdrop())

	_cards_root = Node2D.new()
	add_child(_cards_root)
	# 牌堆和手上那张牌背先建出来。_refresh 会在布局跑之前就被状态变化叫到，
	# 那时候没有这两个节点会直接踩空。
	_pile_card = UnoCard2D.new()
	_cards_root.add_child(_pile_card)
	_deck_card = UnoCard2D.new()
	_cards_root.add_child(_deck_card)

	_build_ui()
	resized.connect(_layout)


func setup_solo(ai_count := 2) -> void:
	_solo_ai_count = clamp(ai_count, 1, 3)
	var players: Array = [{"peer_id": SOLO_PEER, "name": tr("你"), "is_ai": false}]
	var names := [tr("小红"), tr("小蓝"), tr("小绿")]
	for i in _solo_ai_count:
		players.append({
			"peer_id": SOLO_PEER + i + 1,
			"name": names[i],
			"is_ai": true,
		})

	_room = null
	_start_game(players, {})
	if _game != null:
		_game.start_round()
	if _again_button != null:
		_again_button.visible = true

	# 牌面贴图是运行时烘的（见 ui/card_art.gd），第一局开局前等它一下。
	# 之后就一直命中缓存，重开一局是瞬时的。
	await UnoCardArt.ensure_baked()
	_layout()
	_refresh()


## 联机入口。app.gd 收到开局广播后调用，两端都会走这里。
func setup_networked(room: Room, players: Array, config: Dictionary) -> void:
	_room = room
	_start_game(players, config)
	if _game == null:
		return
	_game.bind_room(room)

	room.attach_game(_game)
	room.game_broadcast.connect(_on_net_broadcast)
	room.game_snapshot.connect(_on_net_snapshot)

	# 开局由房主发起。客户端等主机发来的第一份快照和手牌。
	if room.is_host():
		_game.start_round()
	# 客户端点了也没用：重发只能由房主发起，不然两边的牌对不上
	if _again_button != null:
		_again_button.visible = room.is_host()
	await UnoCardArt.ensure_baked()
	_layout()
	_refresh()


## 造一个 UnoGame 并接上信号。单机和联机共用。
func _start_game(players: Array, config: Dictionary) -> void:
	if _game != null:
		_game.queue_free()
	_game = UnoGame.new()
	_game.name = "UnoGame"
	add_child(_game)
	_game.state_changed.connect(_refresh)
	_game.event_played.connect(_on_played)
	_game.event_drew.connect(_on_drew)
	_game.event_log.connect(_set_log)
	_players = players
	_game.setup(players, config)


func _on_net_broadcast(payload: PackedByteArray) -> void:
	if _game != null:
		_game.on_remote_message(payload)


func _on_net_snapshot(snapshot: Dictionary) -> void:
	if _game != null:
		_game.apply_snapshot(snapshot)


func local_peer() -> int:
	return _game.local_peer_id() if _game != null else SOLO_PEER


## 重开一局。单机自己重发就行；联机只有房主能点——
## 重发要保证所有人看到同一副牌，客户端自己重发只会跟主机对不上。
func _on_again() -> void:
	if _room == null:
		setup_solo(_solo_ai_count)
	elif _room.is_host() and _game != null:
		_game.start_round()


## 新一局：手牌节点全清掉重建，免得上一局的牌串进来。
func _clear_hand() -> void:
	for card in _hand_cards:
		card.queue_free()
	_hand_cards.clear()
	_hand_order = []
	_selected = -1
	_has_play_from = false


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
	_again_button = again
	again.pressed.connect(_on_again)
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
	var hand: Array = _game.state().get("my_hand", []) if _game != null else []
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
	if _game == null:
		return
	var s := _game.state()
	if s.is_empty():
		return

	# 这一份状态对应的是一局新的牌，手牌节点全清掉重来
	if int(s.get("round", 0)) != _round:
		_round = int(s.get("round", 0))
		_clear_hand()
	# 手牌也是状态的一部分；_sync_hand 里会顺手重排
	_sync_hand()

	# 弃牌堆顶
	_pile_card.set_card(int(s.get("top_card", -1)), true)

	# 各家张数
	_players = s.get("players", [])
	var parts := PackedStringArray()
	for p in _players:
		parts.append("%s %d" % [String(p["name"]), int(p["count"])])
	_counts_label.text = "　".join(parts)

	# 当前颜色 + 方向
	var color_index := int(s.get("active_color", -1))
	_color_label.text = UnoDeck.COLOR_NAMES[color_index] if color_index >= 0 else "?"
	_color_label.add_theme_color_override("font_color",
		UnoCardPainter.COLOR_FILL.get(color_index, Color.BLACK))
	_direction_label.text = tr("顺时针") if int(s.get("direction", 1)) > 0 \
		else tr("逆时针")

	# 状态
	var current := int(s.get("current", 0))
	if bool(s.get("finished", false)):
		_status_label.text = tr("%s 赢了！") % _name_of(int(s.get("winner", 0)))
	elif int(s.get("color_chooser", 0)) != 0:
		_status_label.text = tr("%s 在选颜色…") % _name_of(int(s["color_chooser"]))
	elif current == local_peer():
		var hint := tr("轮到你了")
		var pending := int(s.get("pending_draw", 0))
		if pending > 0:
			hint += tr("　（要摸 %d 张，或者叠牌）") % pending
		elif bool(s.get("drawn_this_turn", false)):
			hint += tr("　（出牌，或者过牌）")
		else:
			hint += tr("　（点牌堆摸牌）")
		_status_label.text = hint
	else:
		_status_label.text = tr("%s 的回合…") % _name_of(current)

	_color_picker.visible = int(s.get("color_chooser", 0)) == local_peer()


func _name_of(peer_id: int) -> String:
	for p in _players:
		if int(p["peer_id"]) == peer_id:
			return String(p["name"])
	return "?"


func _set_log(text: String) -> void:
	_log_label.text = text


# ---------------------------------------------------------------- 回合驱动

func _process(delta: float) -> void:
	# 联机时由房间层统一 tick（两端一致）；单机这里自己推，AI 才会走。
	if _room == null and _game != null:
		_game.tick(delta)


## 权威端确认有人出牌了。真人点的和 AI 打的都会走到这里。
func _on_played(peer_id: int, card: int) -> void:
	_animate_play(card, _source_position(peer_id, card), peer_id)


func _on_drew(peer_id: int, count: int) -> void:
	# 只有自己摸牌才看得见牌飞进手里；别人摸了几张看日志就够了
	if peer_id == local_peer() and count > 0:
		_animate_draw()


## 算出「这张牌是从哪飞出来的」，用来做起飞点。
func _source_position(peer: int, card: int) -> Vector2:
	if peer == local_peer():
		# 事件是权威端处理完之后才回来的，那时这张牌已经从手牌里删掉了，
		# 所以起飞点要看出牌前记下来的那个位置。
		if _has_play_from:
			return _play_from
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


# ---------------------------------------------------------------- 输入

func _gui_input(event: InputEvent) -> void:
	if _game == null or _busy or _color_picker.visible:
		return
	var s := _game.state()
	if s.is_empty() or bool(s.get("finished", false)):
		return
	if int(s.get("current", 0)) != local_peer():
		return
	# 等别人定颜色的时候不能出牌，规则那边也会拒，这里先挡住省一次往返
	if int(s.get("color_chooser", 0)) != 0:
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
	# 记下起飞点：确认报文回来时这张牌已经不在手牌里了
	if index < _hand_cards.size():
		_play_from = (_hand_cards[index] as UnoCard2D).position
		_has_play_from = true
	_selected = -1
	_layout_hand()
	_game.submit(UnoMessages.encode_play(card, -1))


func _on_color_chosen(color: int) -> void:
	_color_picker.visible = false
	_game.submit(UnoMessages.encode_choose_color(color))


func _on_say_uno() -> void:
	_game.submit(UnoMessages.encode_say_uno())


## 摸牌。入口有两个：点牌堆，或者点底部那个「摸牌」按钮。
## 能不能摸由权威端判定，这里只管把意图发出去。
func _on_draw() -> void:
	if _game == null or _busy or _color_picker.visible:
		return
	_game.submit(UnoMessages.encode_draw())


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
	_game.submit(UnoMessages.encode_pass())
