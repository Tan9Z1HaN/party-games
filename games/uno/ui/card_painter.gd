class_name UnoCardPainter
extends Node2D

## 只负责「把一张 UNO 牌画出来」，画在原点，尺寸 SIZE。
##
## 它**不参与游戏逻辑**，唯一用途是被 tools/gen_uno_card_art.gd 调用来
## 烘出牌面贴图。游戏里跑的是烘好的 PNG + 伪 3D shader，见 card_2d.gd。
##
## 为什么绕这么一圈：参考项目的伪 3D 是靠 shader 里的透视除法做的，
## 而 shader 的 TEXTURE 是一张贴图。CanvasItem 用 _draw() 画出来的东西
## 没有「一张贴图」可言（文字用的是字体图集，多边形用的是白点图），
## 透视数学根本套不上去。所以把自绘结果烘成贴图，问题就没了。
##
## **改了这个文件必须重跑一遍烘焙**，否则游戏里还是旧牌面：
##   godot --path . --script res://tools/gen_uno_card_art.gd

const SIZE := Vector2(148, 216)

## 牌面配色。深色描边 + 高饱和填充，小尺寸下辨识度最高。
const COLOR_FILL := {
	UnoDeck.C.RED: Color(0.86, 0.24, 0.22),
	UnoDeck.C.YELLOW: Color(0.96, 0.74, 0.13),
	UnoDeck.C.GREEN: Color(0.24, 0.65, 0.33),
	UnoDeck.C.BLUE: Color(0.16, 0.48, 0.88),
	UnoDeck.C.WILD: Color(0.20, 0.20, 0.24),
}

## 卡牌的「逻辑尺寸」。贴图按 BAKE_SCALE 倍烘，游戏里再用 sprite 缩回来，
## 这样放大时不会糊。
const BAKE_SCALE := 2.0

## 卡 = -1 表示牌背。
var card := -1
var face_up := true


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

	draw_style_box(_box(Color(0.98, 0.98, 1.0), 14,
		Color(0.15, 0.15, 0.2, 0.9), 3), rect)
	var inner := Rect2(rect.position + Vector2(11, 11), rect.size - Vector2(22, 22))
	draw_style_box(_box(fill, 10, Color(1, 1, 1, 0.35), 2), inner)

	_draw_face_mark(face, color, inner)
	_draw_corners(face, color)


## 牌背。深色底加一个红圈，远看就是一张扣着的牌。
func _draw_back(rect: Rect2) -> void:
	draw_style_box(_box(Color(0.16, 0.17, 0.24), 14,
		Color(0.05, 0.05, 0.08), 3), rect)
	var center := Vector2.ZERO
	_draw_ellipse(center, Vector2(SIZE.x * 0.34, SIZE.x * 0.25), -0.35,
		Color(0.86, 0.24, 0.22))
	_draw_ellipse(center, Vector2(SIZE.x * 0.27, SIZE.x * 0.185), -0.35,
		Color(0.16, 0.17, 0.24))
	_draw_text("UNO", center + Vector2(0, 11), 40, Color(0.98, 0.98, 1.0))


## 牌面中央的图案。没有美术资源，就用几何形状凑——
## 数字牌是数字，功能牌画形状，万能牌画四色扇形。
func _draw_face_mark(face: int, color: int, inner: Rect2) -> void:
	var center := inner.get_center()
	match face:
		UnoDeck.F.SKIP:
			# 标准 UNO 的「跳过」就是一个带斜杠的圈
			_draw_ellipse(center, Vector2(SIZE.x * 0.25, SIZE.x * 0.19), -0.35,
				Color(1, 1, 1, 0.95))
			_draw_ellipse(center, Vector2(SIZE.x * 0.22, SIZE.x * 0.16), -0.35,
				COLOR_FILL[color])
			draw_line(center + Vector2(-34, 32), center + Vector2(34, -32),
				Color(1, 1, 1, 0.98), 13.0)
			draw_line(center + Vector2(-34, 32), center + Vector2(34, -32),
				COLOR_FILL[color], 9.0)
		UnoDeck.F.REVERSE:
			# 两个反向箭头，用三角形加一条横线拼
			for dy in [-20.0, 20.0]:
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
			_draw_wild_wedges(center)
		UnoDeck.F.WILD4:
			_draw_wild_wedges(center)
			_draw_text("+4", center + Vector2(0, 8), 40, Color(1, 1, 1, 0.98))
		_:
			# 数字牌：白椭圆 + 深色数字，跟真牌一个套路
			_draw_ellipse(center, Vector2(SIZE.x * 0.32, SIZE.x * 0.245), -0.35,
				Color(1, 1, 1, 0.94))
			_draw_text(str(face), center + Vector2(0, 33), 92,
				COLOR_FILL[color].darkened(0.18))


## 万能牌的四色扇形
func _draw_wild_wedges(center: Vector2) -> void:
	var radius := SIZE.x * 0.28
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
	_draw_ellipse(center, Vector2(radius * 0.5, radius * 0.38), -0.35,
		Color(0.16, 0.17, 0.24))
	# 万能 +4 的中央留大一点，不然白色 "+4" 压在四色扇形上看不清
	if card >= 0 and UnoDeck.face_of(card) == UnoDeck.F.WILD4:
		_draw_ellipse(center, Vector2(radius * 0.78, radius * 0.62), -0.35,
			Color(0.16, 0.17, 0.24))


## 左上和右下角的角标，跟真牌一样——叠在一起时也能认出是什么牌。
## 白色画在彩色底上：一开始用的是牌面本身的颜色，等于没画。
func _draw_corners(face: int, _color: int) -> void:
	var text := _face_label(face)
	var ink := Color(1, 1, 1, 0.88)
	_draw_text(text, Vector2(-SIZE.x * 0.5 + 30, -SIZE.y * 0.5 + 34), 28, ink)
	_draw_text(text, Vector2(SIZE.x * 0.5 - 30, SIZE.y * 0.5 - 34), 28, ink)


func _face_label(face: int) -> String:
	match face:
		UnoDeck.F.SKIP: return "S"
		UnoDeck.F.REVERSE: return "R"
		UnoDeck.F.DRAW2: return "+2"
		UnoDeck.F.WILD: return "W"
		UnoDeck.F.WILD4: return "+4"
	return str(face)


func _draw_ellipse(center: Vector2, radii: Vector2, angle: float,
		color: Color, steps := 56) -> void:
	var points := PackedVector2Array()
	for i in steps:
		var a := TAU * float(i) / float(steps)
		points.append(center + Vector2(cos(a) * radii.x, sin(a) * radii.y).rotated(angle))
	draw_colored_polygon(points, color)


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
