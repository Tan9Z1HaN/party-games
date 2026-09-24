class_name UnoCard2D
extends Node2D

## 一张 UNO 牌。用 _draw() 自己画，不用贴图——
## 项目里还没有牌面美术，而且自绘的圆角矩形加文字在任何分辨率下都清晰，
## 改配色也只是改几个常量。
##
## **伪 3D 靠的是 Node2D 的 transform 三件套，不是真 3D：**
##   rotation   扇形展开的角度
##   scale.y    纵向压缩 —— 模拟牌往后倒下去的透视缩短
##   skew       横向错切 —— 模拟绕竖轴转过来的侧面
##
## 三者叠加就足够像了，而且全程 2D：没有相机、没有光照、没有 3D 场景的开销。
## 这也是「伪 3D 卡牌 UI」这类做法的核心——把一个平面图形错切一下，
## 眼睛就会自己脑补出体积。

const SIZE := Vector2(148, 216)

## 牌面配色。深色描边 + 高饱和填充，小尺寸下辨识度最高。
const COLOR_FILL := {
	UnoDeck.C.RED: Color(0.86, 0.24, 0.22),
	UnoDeck.C.YELLOW: Color(0.96, 0.74, 0.13),
	UnoDeck.C.GREEN: Color(0.24, 0.65, 0.33),
	UnoDeck.C.BLUE: Color(0.16, 0.48, 0.88),
	UnoDeck.C.WILD: Color(0.20, 0.20, 0.24),
}

var card := -1
var face_up := true

## 被选中时抬起来。由牌桌控制，卡牌本身不处理输入。
var lifted := false

var _base_position := Vector2.ZERO
var _base_rotation := 0.0
var _base_scale := Vector2.ONE
var _base_skew := 0.0


func set_card(value: int, revealed := true) -> void:
	card = value
	face_up = revealed
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(-SIZE * 0.5, SIZE)
	if not face_up:
		_draw_back(rect)
		return

	var face := UnoDeck.face_of(card)
	var color := UnoDeck.color_of(card)
	var fill: Color = COLOR_FILL.get(color, Color.GRAY)

	# 白底 + 深色描边，中间一块颜色
	draw_style_box(_box(Color(0.98, 0.98, 1.0), 14, Color(0.15, 0.15, 0.2, 0.9), 3), rect)
	var inner := Rect2(rect.position + Vector2(11, 11), rect.size - Vector2(22, 22))
	draw_style_box(_box(fill, 10, Color(1, 1, 1, 0.35), 2), inner)

	_draw_face_mark(face, color, inner)
	_draw_corners(face, color)


## 牌背。深色底加一个白圈，远看就是一张扣着的牌。
func _draw_back(rect: Rect2) -> void:
	draw_style_box(_box(Color(0.16, 0.17, 0.24), 14, Color(0.05, 0.05, 0.08), 3), rect)
	var center := Vector2.ZERO
	draw_circle(center, SIZE.x * 0.30, Color(0.86, 0.24, 0.22))
	draw_circle(center, SIZE.x * 0.24, Color(0.16, 0.17, 0.24))
	_draw_text("UNO", center + Vector2(0, 10), 40, Color(0.98, 0.98, 1.0))


## 牌面中央的图案。没有美术资源，就用几何形状凑——
## 数字牌是数字，功能牌画形状，万能牌画四色扇形。
func _draw_face_mark(face: int, color: int, inner: Rect2) -> void:
	var center := inner.get_center()
	match face:
		UnoDeck.F.SKIP:
			draw_circle(center, SIZE.x * 0.22, Color(1, 1, 1, 0.92))
			draw_circle(center, SIZE.x * 0.22, Color(0, 0, 0, 0), false, 6.0, false)
			draw_line(center + Vector2(-30, 30), center + Vector2(30, -30),
				Color(0.86, 0.24, 0.22), 12.0)
		UnoDeck.F.REVERSE:
			# 两个反向箭头，用三角形加一条横线拼
			for dy in [-18.0, 18.0]:
				var tip := center + Vector2(0, dy)
				var back := 26.0
				draw_colored_polygon(PackedVector2Array([
					tip, tip + Vector2(-back, -14), tip + Vector2(-back, 14),
				]), Color(1, 1, 1, 0.95))
				draw_line(tip + Vector2(-back, 0), tip + Vector2(back, 0),
					Color(1, 1, 1, 0.95), 8.0)
		UnoDeck.F.DRAW2:
			_draw_text("+2", center + Vector2(0, 22), 64, Color(1, 1, 1, 0.96))
		UnoDeck.F.WILD:
			_draw_wild_wedges(center, 0)
		UnoDeck.F.WILD4:
			_draw_wild_wedges(center, 0)
			_draw_text("+4", center + Vector2(0, 20), 56, Color(1, 1, 1, 0.96))
		_:
			_draw_text(str(face), center + Vector2(0, 30), 90, Color(1, 1, 1, 0.96))


## 万能牌的四色扇形
func _draw_wild_wedges(center: Vector2, _unused: int) -> void:
	var radius := SIZE.x * 0.26
	var colors := [
		COLOR_FILL[UnoDeck.C.RED], COLOR_FILL[UnoDeck.C.YELLOW],
		COLOR_FILL[UnoDeck.C.GREEN], COLOR_FILL[UnoDeck.C.BLUE],
	]
	for i in 4:
		var from := -PI * 0.5 + i * PI * 0.5
		var points := PackedVector2Array([center])
		var steps := 14
		for s in steps + 1:
			var angle := from + PI * 0.5 * float(s) / float(steps)
			points.append(center + Vector2(cos(angle), sin(angle)) * radius)
		draw_colored_polygon(points, colors[i])
	draw_circle(center, radius * 0.42, Color(0.16, 0.17, 0.24))


## 左上和右下角的角标，跟真牌一样——叠在一起时也能认出是什么牌
func _draw_corners(face: int, color: int) -> void:
	var text := _face_label(face)
	var tint: Color = Color(0.2, 0.2, 0.25) if color == UnoDeck.C.WILD else COLOR_FILL[color]
	_draw_text(text, Vector2(-SIZE.x * 0.5 + 26, -SIZE.y * 0.5 + 34), 30, tint)
	_draw_text(text, Vector2(SIZE.x * 0.5 - 26, SIZE.y * 0.5 - 16), 30, tint)


func _face_label(face: int) -> String:
	match face:
		UnoDeck.F.SKIP: return "S"
		UnoDeck.F.REVERSE: return "R"
		UnoDeck.F.DRAW2: return "+2"
		UnoDeck.F.WILD: return "W"
		UnoDeck.F.WILD4: return "+4"
	return str(face)


func _draw_text(text: String, center: Vector2, font_size: int, color: Color) -> void:
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var extent := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	draw_string(font, center - Vector2(extent.x * 0.5, -extent.y * 0.28),
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _box(fill: Color, radius: int, border: Color, border_width: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.set_corner_radius_all(radius)
	if border_width > 0:
		box.border_width_top = border_width
		box.border_width_bottom = border_width
		box.border_width_left = border_width
		box.border_width_right = border_width
		box.border_color = border
	return box


# ---------------------------------------------------------------- 伪 3D 姿态

## 按「离扇形中心的格数」摆好姿态。offset 为 0 时是正中那张。
##
## 参数集中在一个字典里，方便对着参考项目调手感：
##   spread   每格转多少弧度
##   spacing  每格横向间距
##   arc      越靠边往下掉多少（做成一个微微上拱的扇面）
##   lean     伪 3D 强度：纵向压缩 + 横向错切都按它缩放
func set_fan_pose(offset: float, cfg: Dictionary = {}) -> void:
	var spread: float = cfg.get("spread", 0.055)
	var spacing: float = cfg.get("spacing", 92.0)
	var arc: float = cfg.get("arc", 12.0)
	var lean: float = cfg.get("lean", 0.11)

	_base_rotation = offset * spread
	_base_position = Vector2(offset * spacing, absf(offset) * arc)
	# 越靠边越「侧过去」：纵向压一点、横向错切一点
	_base_scale = Vector2(1.0, 1.0 - absf(offset) * lean * 0.35)
	_base_skew = offset * lean

	# 中间的牌压在两边上面，扇形才立得住
	z_index = int(60 - absf(offset) * 6.0)
	_apply_pose(0.0)


## 选中时抬起：向上位移 + 放大 + 摆正，让玩家一眼看出选的是哪张。
func set_lifted(value: bool) -> void:
	if lifted == value:
		return
	lifted = value
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if lifted:
		tween.set_parallel(true)
		tween.tween_property(self, "position", _base_position + Vector2(0, -54), 0.16)
		tween.tween_property(self, "scale", _base_scale * 1.14, 0.16)
		tween.tween_property(self, "rotation", 0.0, 0.16)
		tween.tween_property(self, "skew", 0.0, 0.16)
		z_index = 90
	else:
		tween.set_parallel(true)
		tween.tween_property(self, "position", _base_position, 0.16)
		tween.tween_property(self, "scale", _base_scale, 0.16)
		tween.tween_property(self, "rotation", _base_rotation, 0.16)
		tween.tween_property(self, "skew", _base_skew, 0.16)
		z_index = int(60 - absf((_base_position.x) / 92.0) * 6.0)


## 立刻把姿态套上去，不走动画。布局重排时用（比如刚发完牌）。
func snap_to_pose() -> void:
	_apply_pose(0.0)


func _apply_pose(_unused: float) -> void:
	position = _base_position
	rotation = _base_rotation
	scale = _base_scale
	skew = _base_skew
