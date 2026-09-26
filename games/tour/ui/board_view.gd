class_name TourBoardView
extends Control

## 点了某一格。牌桌拿去显示详情（地价、业主、过路费）。
signal cell_tapped(cell: int)

## 点了棋盘上任意一处（含没点中格子）。牌桌拿它做「点一下跳过抽卡动画」。
signal tapped_anywhere

## 棋盘：40 格围成一圈，中间留空给骰子和信息。
##
## **整个棋盘是一个 Control，用 _draw() 画**，不给每格建节点：
## 40 个格子 + 6 个棋子 + 各种角标，用节点要几百个，手机上光布局就够呛；
## 而棋盘是静态的，只有状态变化时才需要重画。
##
## 它只认 TourRules.snapshot() 给的状态字典（见 rules.gd 里的说明），
## 不碰规则对象——联机时换一份来源就行。

## 玩家颜色。最多 6 人，颜色之间要够区分（红绿蓝黄紫橙）
const PLAYER_COLORS := [
	Color(0.86, 0.24, 0.22),
	Color(0.16, 0.48, 0.88),
	Color(0.24, 0.62, 0.33),
	Color(0.94, 0.66, 0.11),
	Color(0.60, 0.34, 0.80),
	Color(0.92, 0.45, 0.16),
]

## 八个城市组的底色。同组的格子颜色一样，玩家一眼能看出"哪几块是一组"。
const GROUP_COLORS := [
	Color(0.98, 0.87, 0.83),   # 暖冬
	Color(0.98, 0.93, 0.80),   # 山水
	Color(0.93, 0.90, 0.98),   # 西北
	Color(0.84, 0.94, 0.88),   # 华中
	Color(0.83, 0.92, 0.98),   # 华东
	Color(0.98, 0.85, 0.90),   # 网红
	Color(0.90, 0.93, 0.84),   # 华北·东北
	Color(0.98, 0.80, 0.76),   # 一线
]

const SPECIAL_COLOR := Color(0.93, 0.94, 0.96)
const CELL_GAP := 3.0
const CELL_RADIUS := 10
const TEXT_INK := Color(0.14, 0.15, 0.18)
const DIM_INK := Color(0.45, 0.47, 0.52)
## 骰子晃动的时间。这段时间里画的是乱跳的点数，之后才落回真实点数。
const DICE_ROLL_TIME := 0.45

var _state := {}
## 玩家的绘制顺序（下标 → 颜色）。用 peer_id 排序保证两端一致。
var _order: Array[int] = []
## 正在移动的棋子：peer_id -> 浮点格号（12.4 表示从 12 往 13 走了 40%）。
## 逐格跳动的动画只在表现层，规则那边早就走到位了。
var _moving := {}
## 抽卡动画：{text, chance, t}。t 从 0 走到 1 是一整段。
var _card := {}
## 骰子摇动动画的进度，负值表示不在摇（直接画真实点数）。
var _dice_roll_t := -1.0
## 刚落地的那一格会亮一下：主界面每帧把衰减后的亮度送进来。
var _flash_cell := -1
var _flash_amount := 0.0
## 点格子看详情
var selected_cell := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


func _gui_input(event: InputEvent) -> void:
	var point := Vector2.INF
	if event is InputEventMouseButton and event.pressed:
		point = event.position
	elif event is InputEventScreenTouch and event.pressed:
		point = event.position
	if point == Vector2.INF:
		return
	tapped_anywhere.emit()
	var cell := cell_at(point)
	if cell < 0:
		return
	selected_cell = cell
	queue_redraw()
	cell_tapped.emit(cell)


## 点在哪一格。40 次矩形判定，比给每格建节点省得多。
func cell_at(point: Vector2) -> int:
	for cell in TourBoard.size():
		if cell_rect(cell).has_point(point):
			return cell
	return -1


func apply(state: Dictionary) -> void:
	_state = state
	_order.clear()
	for row in state.get("players", []):
		_order.append(int(row["peer_id"]))
	_order.sort()
	queue_redraw()


func set_moving(peer_id: int, float_cell: float) -> void:
	_moving[peer_id] = float_cell
	queue_redraw()


func clear_moving() -> void:
	if _moving.is_empty():
		return
	_moving.clear()
	queue_redraw()


func set_card_anim(text: String, chance: bool, t: float) -> void:
	_card = {"text": text, "chance": chance, "t": t}
	queue_redraw()


func clear_card_anim() -> void:
	if _card.is_empty():
		return
	_card.clear()
	queue_redraw()


## 摇骰子：t 从 0 走到 DICE_ROLL_TIME 期间画乱跳的点数。
## 负值收工，直接画真实点数。乱跳也是状态——主界面每帧推进它。
func set_dice_anim(t: float) -> void:
	if is_equal_approx(_dice_roll_t, t):
		return
	_dice_roll_t = t
	queue_redraw()


## 刚落地的那一格亮一下。amount 从 1 衰减到 0，主界面每帧送进来。
func set_flash(cell: int, amount: float) -> void:
	var want := cell if amount > 0.0 else -1
	if _flash_cell == want and is_equal_approx(_flash_amount, maxf(amount, 0.0)):
		return
	_flash_cell = want
	_flash_amount = maxf(amount, 0.0)
	queue_redraw()


func color_of(peer_id: int) -> Color:
	var index := _order.find(peer_id)
	if index < 0:
		return DIM_INK
	return PLAYER_COLORS[index % PLAYER_COLORS.size()]


## 棋盘用满整个可用区域（竖屏上是个竖长条）。
##
## 不强制正方形：手机竖屏本来就高，做正方会上下各空一大块，格子也被压小。
## 拉长之后格子更高，名字放得下，纵向空间也不浪费。
func board_area() -> Vector2:
	return size


## 比例尺：居中那些东西（骰子、提示）按短边算，免得竖屏上大得离谱。
func board_scale() -> float:
	return minf(size.x, size.y)


func cell_rect(cell: int) -> Rect2:
	return TourBoard.cell_rect(cell, board_area())


## 棋子位置：落在同一格的棋子按角度散开，不叠在一起。
func token_position(cell: int, index_in_cell: int, count_in_cell: int) -> Vector2:
	var rect := cell_rect(cell)
	var center := rect.get_center()
	# 名字画在偏上、棋子放在下半部：两者错开，不然棋子正压在名字上
	center.y += rect.size.y * 0.30
	if count_in_cell <= 1:
		return center
	# 同格的人越多，散得越开：棋子调大之后，固定的散开半径会让它们叠成一坨
	var radius := rect.size.x * (0.18 + 0.04 * float(count_in_cell))
	# 从正右方开始排：两个人时就是左右各一个（格子是横着宽的），
	# 从正上方开始的话两个人会上下叠着挤在中间
	var angle := TAU * float(index_in_cell) / float(count_in_cell)
	return center + Vector2(cos(angle), sin(angle)) * radius


## 浮点格号 → 位置。在两个相邻格子的中心之间插值，读起来就是"逐格跳"。
##
## arc > 0 时再加一段抛物线：起跳和落地贴地、中间最高。
## 光是平移也能看出在走，但加上弧线才像"跳"，一格一格的感觉才出得来。
func position_between(float_cell: float, arc := 0.0) -> Vector2:
	var total := TourBoard.size()
	var base := int(floor(float_cell))
	var t := float_cell - float(base)
	var a := cell_rect(posmod(base, total)).get_center()
	var b := cell_rect(posmod(base + 1, total)).get_center()
	var pos := a.lerp(b, t)
	if arc > 0.0:
		pos.y -= sin(PI * t) * arc
	return pos


## 棋子的位置表：每个还没出局的人一条，同格的按 index/count 散开。
##
## 抽成纯函数是为了能测——这段原来被误插进 _draw_card_anim() 里，
## 结果**只有翻卡的那一瞬间棋子才画得出来**，平时满盘看不到人。
## 单测拿不到画面，但至少能盯住"谁都算出来了"。
func token_placements(state: Dictionary) -> Array:
	var occupancy := {}
	for row in state.get("players", []):
		if bool(row["out"]):
			continue
		var cell := int(row["pos"])
		if not occupancy.has(cell):
			occupancy[cell] = []
		occupancy[cell].append(int(row["peer_id"]))
	var out: Array = []
	for cell in occupancy:
		var peers: Array = occupancy[cell]
		for i in peers.size():
			out.append({
				"peer_id": int(peers[i]),
				"cell": int(cell),
				"index": i,
				"count": peers.size(),
			})
	return out


func _draw() -> void:
	if _state.is_empty():
		return
	var font := ThemeDB.fallback_font
	if font == null:
		return

	for cell in TourBoard.size():
		_draw_cell(cell, font)
	_draw_center(font)
	_draw_tokens(font)
	_draw_card_anim(font)


## 抽到机会/命运时在中央翻一张卡。
##
## 前 40% 是翻面：背面被横向压扁到一条线，再从线展开成正面——
## 这就是经典的翻牌，两段 `scale.x` 拼出来，不需要贴图也不需要 3D。
## 剩下 60% 停着让人读完，最后 20% 淡出。
func _draw_card_anim(font: Font) -> void:
	if _card.is_empty():
		return
	var t: float = _card.get("t", 0.0)
	var flip := clampf(t / 0.4, 0.0, 1.0)
	var face_up := flip >= 0.5
	var squash := absf(1.0 - flip * 2.0)     # 1 → 0 → 1
	var alpha := 1.0 if t < 0.8 else clampf((1.0 - t) / 0.2, 0.0, 1.0)

	var box := Vector2(board_scale() * 0.62, board_scale() * 0.30)
	box.x = maxf(box.x * squash, 2.0)
	var rect := Rect2(Vector2(size.x, size.y) * 0.5 - box * 0.5, box)
	var chance: bool = bool(_card.get("chance", false))

	if not face_up:
		# 卡背：深色底 + 一个问号
		draw_style_box(_box(Color(0.18, 0.20, 0.30, alpha), 18,
			Color(1, 1, 1, alpha * 0.5), 3), rect)
		var mark := "?"
		var mark_size := int(box.y * 0.5)
		var extent0 := font.get_string_size(mark, HORIZONTAL_ALIGNMENT_LEFT, -1, mark_size)
		draw_string(font, rect.get_center() + Vector2(-extent0.x * 0.5, extent0.y * 0.32),
			mark, HORIZONTAL_ALIGNMENT_LEFT, -1, mark_size,
			Color(1, 1, 1, alpha * 0.9))
		return

	# 卡面：白底 + 文案。机会偏暖色、命运偏冷色，一眼分得出来
	var tint := Color(0.94, 0.72, 0.20) if chance else Color(0.36, 0.55, 0.85)
	draw_style_box(_box(Color(1, 1, 1, alpha), 18, tint, 5), rect)
	var text := String(_card.get("text", ""))
	var text_size := int(clampi(box.y * 0.34, 18, 56))
	var extent := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, text_size)
	draw_string(font, rect.get_center() + Vector2(-extent.x * 0.5, extent.y * 0.32),
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, text_size, Color(0.14, 0.15, 0.18, alpha))


## 画棋子。**必须在 _draw() 里调用**，别挪进 _draw_card_anim()——
## 那段只在抽到卡片时才有机会跑，棋子会整局都看不见。
func _draw_tokens(font: Font) -> void:
	var lift := cell_rect(0).size.y * 0.22
	for entry in token_placements(_state):
		var peer := int(entry["peer_id"])
		# 正在跳的人不在这里画：下面那个插值的位置才是他现在的样子
		if _moving.has(peer):
			continue
		_draw_token_at(peer, token_position(int(entry["cell"]),
			int(entry["index"]), int(entry["count"])), font)
	# 正在跳的棋子画在最上面
	for peer_id in _moving:
		_draw_token_at(int(peer_id),
			position_between(float(_moving[peer_id]), lift), font)


func _draw_cell(cell: int, font: Font) -> void:
	var rect := cell_rect(cell).grow(-CELL_GAP * 0.5)
	var kind := TourBoard.kind_of(cell)
	var group := TourBoard.group_of(cell)

	var fill := SPECIAL_COLOR
	if TourBoard.is_purchasable(cell):
		fill = GROUP_COLORS[group] if group >= 0 else Color(0.90, 0.91, 0.93)
	draw_style_box(_box(fill, CELL_RADIUS, Color(0.78, 0.79, 0.84), 1), rect)

	# 有主：加一圈玩家色描边 + 右下角的等级点
	var owner := int(_state.get("owner", {}).get(cell, 0))
	if owner != 0:
		draw_style_box(_box(Color(0, 0, 0, 0), CELL_RADIUS,
			color_of(owner), 5), rect)
		_draw_level_dots(rect, int(_state.get("level", {}).get(cell, 1)))

	var label := TourBoard.short_name_of(cell)
	# 名字越长字越小：一格只有 98 像素，四个字已经是极限
	var font_size := clampi(int(rect.size.x / maxf(1.0, float(label.length())) * 0.92),
		14, 30)
	var extent := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var color := TEXT_INK if TourBoard.is_purchasable(cell) else DIM_INK
	var name_at := rect.get_center() + Vector2(0, -rect.size.y * 0.14)
	draw_string(font, name_at + Vector2(-extent.x * 0.5, extent.y * 0.32),
		label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

	if cell == selected_cell:
		draw_style_box(_box(Color(0, 0, 0, 0), CELL_RADIUS, Color(0.10, 0.12, 0.20), 3),
			rect)

	# 刚落到这一格：叠一层亮边，衰减着收掉。人很多的时候一眼看出是谁落在哪
	if cell == _flash_cell and _flash_amount > 0.0:
		var glow := Color(1.0, 0.98, 0.72, 0.85 * _flash_amount)
		draw_style_box(_box(Color(1.0, 0.97, 0.60, 0.35 * _flash_amount),
			CELL_RADIUS, glow, 4), rect)


## 棋盘正中间那块空地用来放骰子和提示。
## 40 格围成一圈，中间本来就是空的——不放东西就是一大片浪费。
func _draw_center(font: Font) -> void:
	var center := Vector2(size.x * 0.5, size.y * 0.5)
	var dice: Array = _state.get("dice", [])
	if dice.size() == 2:
		var faces := [int(dice[0]), int(dice[1])]
		if _dice_roll_t >= 0.0 and _dice_roll_t < DICE_ROLL_TIME:
			# 摇动期间画乱跳的点数。用「帧号 + 真实点数」播种，
			# 同一帧画出来的两颗骰子在两端一致，也不动全局随机数。
			var frame := int(_dice_roll_t / 0.06)
			var rng := RandomNumberGenerator.new()
			rng.seed = hash(Vector3i(frame, int(dice[0]), int(dice[1])))
			faces = [rng.randi_range(1, 6), rng.randi_range(1, 6)]
		var box := board_scale() * 0.11
		var gap := box * 0.35
		_draw_die(center + Vector2(-(box + gap) * 0.5, -box * 0.5), box, int(faces[0]))
		_draw_die(center + Vector2((box + gap) * 0.5, -box * 0.5), box, int(faces[1]))

	var hint := String(_state.get("hint", ""))
	if hint.is_empty():
		return
	var font_size := int(board_scale() * 0.042)
	var extent := font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	draw_string(font, center + Vector2(-extent.x * 0.5, board_scale() * 0.16),
		hint, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, DIM_INK)


## 一颗骰子：圆角方块 + 点数。用画的而不是贴图，改大小不用重做资源。
func _draw_die(center: Vector2, box: float, value: int) -> void:
	var rect := Rect2(center, Vector2(box, box))
	draw_style_box(_box(Color(1, 1, 1), int(box * 0.22),
		Color(0.75, 0.76, 0.80), 3), rect)
	if value <= 0:
		return
	var pip := box * 0.09
	var off := box * 0.26
	# 点数的位置照标准骰子摆：1/3/5 走对角线，2/4/6 补两边
	var spots: Array = []
	match value:
		1: spots = [Vector2(0, 0)]
		2: spots = [Vector2(-off, -off), Vector2(off, off)]
		3: spots = [Vector2(-off, -off), Vector2(0, 0), Vector2(off, off)]
		4: spots = [Vector2(-off, -off), Vector2(off, -off),
			Vector2(-off, off), Vector2(off, off)]
		5: spots = [Vector2(-off, -off), Vector2(off, -off), Vector2(0, 0),
			Vector2(-off, off), Vector2(off, off)]
		6: spots = [Vector2(-off, -off), Vector2(off, -off),
			Vector2(-off, 0), Vector2(off, 0),
			Vector2(-off, off), Vector2(off, off)]
	var middle := center + Vector2(box * 0.5, box * 0.5)
	for spot in spots:
		draw_circle(middle + spot, pip, Color(0.16, 0.17, 0.22))


## 等级用右下角的点表示，1~4 个。不写数字：格子上已经没地方了。
func _draw_level_dots(rect: Rect2, level: int) -> void:
	var dot := rect.size.x * 0.09
	var gap := dot * 1.6
	var y := rect.end.y - dot * 1.6
	var x := rect.end.x - dot * 1.6
	for i in level:
		draw_circle(Vector2(x - float(i) * gap, y), dot, Color(0.16, 0.17, 0.22))


func _draw_token_at(peer_id: int, pos: Vector2, _font: Font) -> void:
	# 棋子要在 1080 宽的屏上离着半米也看得见，所以别太小
	var radius := board_scale() / 11.0 * 0.19
	draw_circle(pos, radius * 1.25, Color(1, 1, 1, 0.92))
	draw_circle(pos, radius, color_of(peer_id))
	# 当前行动的人加一圈白环，一眼看出轮到谁
	if int(_state.get("current", 0)) == peer_id:
		draw_arc(pos, radius * 1.6, 0.0, TAU, 24, Color(0.10, 0.12, 0.20), 4.0)


func _box(fill: Color, radius: int, border: Color, width: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.set_corner_radius_all(radius)
	if width > 0:
		box.border_width_top = width
		box.border_width_bottom = width
		box.border_width_left = width
		box.border_width_right = width
		box.border_color = border
	return box
