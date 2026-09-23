class_name HsvPicker
extends VBoxContainer

## HSV 取色器。上面一条色相带，下面一个饱和度/明度方块——
## 就是绘画软件里那个东西，颜色随便挑，不是固定色板。
##
## 两块都是运行时生成的贴图，不依赖任何美术资源：
## 色相带是 1×N 的彩虹，方块按当前色相生成。
## 方块只有 64×64，换色相时重算一遍也就几毫秒。

signal color_changed(color: Color)

const SV_SIZE := 72          ## 方块贴图边长
const HUE_STEPS := 96        ## 色相带贴图宽度

var _hue := 0.0
var _saturation := 1.0
var _value := 1.0

var _hue_rect: TextureRect
var _sv_rect: TextureRect
var _preview: ColorRect
var _dragging_hue := false
var _dragging_sv := false


func _ready() -> void:
	add_theme_constant_override("separation", 8)

	_hue_rect = TextureRect.new()
	_hue_rect.custom_minimum_size = Vector2(0, 40)
	_hue_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_hue_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_hue_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	_hue_rect.texture = _make_hue_texture()
	_hue_rect.gui_input.connect(_on_hue_input)
	add_child(_hue_rect)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	add_child(row)

	_sv_rect = TextureRect.new()
	_sv_rect.custom_minimum_size = Vector2(260, 150)
	_sv_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_sv_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_sv_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	_sv_rect.gui_input.connect(_on_sv_input)
	row.add_child(_sv_rect)

	_preview = ColorRect.new()
	_preview.custom_minimum_size = Vector2(78, 150)
	_preview.color = get_color()
	# 预览块本身不该吃掉点击，不然会挡住下面的控件
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_preview)

	_refresh_sv()


func get_color() -> Color:
	return Color.from_hsv(_hue, _saturation, _value)


func set_color(color: Color) -> void:
	_hue = color.h
	_saturation = color.s
	_value = color.v
	_refresh_sv()
	_update_preview()


func _on_hue_input(event: InputEvent) -> void:
	var pos := _pick_position(event, _hue_rect, _dragging_hue)
	if pos.x < 0.0:
		return
	_hue = clampf(pos.x, 0.0, 1.0)
	_refresh_sv()
	_update_preview()
	color_changed.emit(get_color())


func _on_sv_input(event: InputEvent) -> void:
	var pos := _pick_position(event, _sv_rect, _dragging_sv)
	if pos.x < 0.0:
		return
	_saturation = clampf(pos.x, 0.0, 1.0)
	# 方块顶部是明度 1，底部是 0
	_value = clampf(1.0 - pos.y, 0.0, 1.0)
	_update_preview()
	color_changed.emit(get_color())


## 返回 0~1 的归一化位置；不是按下/拖动就返回负值表示忽略。
## 用 dragging 记状态，否则鼠标划过控件时颜色就跟着乱变。
func _pick_position(event: InputEvent, node: Control, dragging: bool) -> Vector2:
	var pressed := false
	var local := Vector2.ZERO

	if event is InputEventScreenTouch:
		pressed = event.pressed
		local = event.position
		_dragging_hue = pressed if node == _hue_rect else _dragging_hue
		_dragging_sv = pressed if node == _sv_rect else _dragging_sv
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		pressed = event.pressed
		local = event.position
		_dragging_hue = pressed if node == _hue_rect else _dragging_hue
		_dragging_sv = pressed if node == _sv_rect else _dragging_sv
	elif event is InputEventScreenDrag or event is InputEventMouseMotion:
		pressed = dragging
		local = event.position
	else:
		return Vector2(-1, -1)

	if not pressed:
		return Vector2(-1, -1)
	var size := node.size
	if size.x <= 0.0 or size.y <= 0.0:
		return Vector2(-1, -1)
	return Vector2(local.x / size.x, local.y / size.y)


func _refresh_sv() -> void:
	_sv_rect.texture = _make_sv_texture(_hue)


func _update_preview() -> void:
	_preview.color = get_color()


## 1×N 的彩虹带
func _make_hue_texture() -> ImageTexture:
	var image := Image.create(HUE_STEPS, 1, false, Image.FORMAT_RGB8)
	for x in HUE_STEPS:
		image.set_pixel(x, 0, Color.from_hsv(float(x) / float(HUE_STEPS), 1.0, 1.0))
	return ImageTexture.create_from_image(image)


## 横轴是饱和度（0 左 1 右），纵轴是明度（1 上 0 下）
func _make_sv_texture(hue: float) -> ImageTexture:
	var image := Image.create(SV_SIZE, SV_SIZE, false, Image.FORMAT_RGB8)
	for y in SV_SIZE:
		var value := 1.0 - float(y) / float(SV_SIZE - 1)
		for x in SV_SIZE:
			var saturation := float(x) / float(SV_SIZE - 1)
			image.set_pixel(x, y, Color.from_hsv(hue, saturation, value))
	return ImageTexture.create_from_image(image)
