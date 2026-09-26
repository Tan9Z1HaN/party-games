class_name LightTheme
extends RefCounted

## 全局浅色主题。
##
## Godot 默认主题是深色的（浅色文字）。只改 Label 的 font_color 是不够的：
## 按钮的 hover / pressed / focus / disabled 各有独立的颜色，漏一个就会在
## 按下或禁用时重新变得看不清；按钮底色来自默认主题的深灰，黑字压上去更糊。
## 所以这一整套必须成套换。
##
## 对话框面板用 panel_style()，普通容器直接挂 build() 返回的 Theme。

const INK := Color(0.10, 0.11, 0.13)
const INK_DIM := Color(0.44, 0.47, 0.52)
const INK_ACCENT := Color(0.09, 0.45, 0.20)
const BACKDROP := Color(0.90, 0.92, 0.96)
const SURFACE := Color(1.0, 1.0, 1.0)
const SURFACE_ALT := Color(0.93, 0.95, 0.99)
const SURFACE_PRESSED := Color(0.78, 0.85, 0.97)
const SURFACE_DISABLED := Color(0.88, 0.89, 0.92)
const FOCUS_RING := Color(0.25, 0.52, 0.95)

## 玻璃质感：半透明的白、一圈亮边、一点投影。
## 底衬是浅色渐变，半透明才看得出来是"玻璃"而不是"白块"。
const GLASS := Color(1.0, 1.0, 1.0, 0.52)
const GLASS_HOVER := Color(1.0, 1.0, 1.0, 0.80)
## 按下时的底色。**刻意用中性灰而不是蓝色**：
## 触摸界面上按钮很容易卡在按下状态（下面 _clear_button_press 在治本），
## 而蓝色的按下色一旦卡住，看着就像"这个按钮被选中了"，很误导。
## 灰色卡住只是稍微深一点，不刺眼。
const GLASS_PRESSED := Color(0.86, 0.87, 0.90, 0.94)
const GLASS_DISABLED := Color(1.0, 1.0, 1.0, 0.26)
const GLASS_BORDER := Color(1.0, 1.0, 1.0, 0.90)
const GLASS_SHADOW := Color(0.12, 0.18, 0.32, 0.18)


static func build() -> Theme:
	var t := Theme.new()

	for tname in ["Label", "Button", "OptionButton", "CheckBox", "CheckButton"]:
		t.set_color("font_color", tname, INK)
		t.set_color("font_hover_color", tname, INK)
		t.set_color("font_pressed_color", tname, INK)
		t.set_color("font_focus_color", tname, INK)
		t.set_color("font_disabled_color", tname, INK_DIM)

	t.set_color("font_color", "LineEdit", INK)
	t.set_color("font_placeholder_color", "LineEdit", INK_DIM)
	t.set_color("font_selected_color", "LineEdit", Color.WHITE)
	t.set_color("caret_color", "LineEdit", INK)
	t.set_color("selection_color", "LineEdit", Color(0.66, 0.79, 0.98))

	t.set_color("font_color", "PopupMenu", INK)
	t.set_color("font_hover_color", "PopupMenu", INK)
	t.set_color("font_disabled_color", "PopupMenu", INK_DIM)
	t.set_stylebox("panel", "PopupMenu", surface_box(SURFACE))
	t.set_stylebox("hover", "PopupMenu", surface_box(GLASS_PRESSED))

	# 按钮有六个状态，**一个都不能漏**：漏掉的状态会退回引擎默认主题，
	# 而默认主题是深色 + 蓝色高亮。之前漏了 hover_pressed，症状是
	# 「点过的那个按钮一直留着浅蓝底」——因为它比 focus 还不显眼，
	# 找了好几轮才反应过来是漏了一个状态。
	for tname in ["Button", "OptionButton", "CheckBox", "CheckButton"]:
		t.set_stylebox("normal", tname, surface_box(GLASS))
		t.set_stylebox("hover", tname, surface_box(GLASS_HOVER))
		t.set_stylebox("pressed", tname, surface_box(GLASS_PRESSED))
		t.set_stylebox("hover_pressed", tname, surface_box(GLASS_PRESSED))
		t.set_stylebox("disabled", tname, surface_box(GLASS_DISABLED))
		t.set_stylebox("focus", tname, focus_box())

	t.set_stylebox("normal", "LineEdit", surface_box(SURFACE))
	t.set_stylebox("focus", "LineEdit", focus_box())

	return t


static func surface_box(color: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(18)
	box.border_width_top = 2
	box.border_width_bottom = 2
	box.border_width_left = 2
	box.border_width_right = 2
	box.border_color = GLASS_BORDER
	box.shadow_color = GLASS_SHADOW
	box.shadow_size = 6
	box.shadow_offset = Vector2(0, 3)
	box.content_margin_left = 22.0
	box.content_margin_right = 22.0
	box.content_margin_top = 12.0
	box.content_margin_bottom = 12.0
	return box


## 焦点样式。
##
## **这里必须是空的**：手机上每次点按钮，按钮都会拿到焦点，如果 focus 画了
## 一圈边框，就会看到"每个按钮外面都有个蓝框"，而且它一直留在那儿——
## 那是给键盘/手柄导航用的提示，触摸界面上纯属干扰。
##
## 代价是键盘和手柄导航时看不出焦点在哪。这个项目是手机聚会游戏，
## 不接受触摸屏的操作都走不到，所以这个代价可以接受；
## 哪天真要接手柄，再把边框加回来（或者按输入设备切换主题）。
static func focus_box() -> StyleBox:
	return StyleBoxEmpty.new()


## 覆盖整屏的面板（菜单、大厅、结算这类）。带内边距，
## 不然内容会顶到屏幕边缘，首字被切、按钮贴边。
static func panel_style() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(1.0, 1.0, 1.0, 0.55)
	box.set_corner_radius_all(0)
	box.content_margin_left = 44.0
	box.content_margin_right = 44.0
	box.content_margin_top = 44.0
	box.content_margin_bottom = 44.0
	return box


static func label(text: String, font_size: int) -> Label:
	var node := Label.new()
	node.text = text
	node.add_theme_font_size_override("font_size", font_size)
	return node


static func button(text: String, font_size: int) -> Button:
	var node := Button.new()
	node.text = text
	node.add_theme_font_size_override("font_size", font_size)
	node.custom_minimum_size = Vector2(0, 56)
	return node


## 铺一层浅色渐变底。默认清除色是深灰，黑字压上去看不清；
## 而且半透明的玻璃按钮需要一层有变化的底衬才像玻璃。
static func backdrop() -> Control:
	var rect := TextureRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE

	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.83, 0.89, 1.0))
	gradient.set_color(1, Color(0.97, 0.89, 0.98))

	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill_from = Vector2(0.0, 0.0)
	texture.fill_to = Vector2(1.0, 1.0)
	texture.width = 256
	texture.height = 256
	rect.texture = texture
	return rect


## 切换界面时让面板淡入 + 轻微放大，别硬切。
static func present(panel: Control, duration := 0.2) -> void:
	panel.visible = true
	panel.modulate.a = 0.0
	panel.pivot_offset = panel.size * 0.5
	panel.scale = Vector2(0.97, 0.97)
	var tween := panel.create_tween()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(panel, "modulate:a", 1.0, duration)
	tween.tween_property(panel, "scale", Vector2.ONE, duration)


static func clear_children(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
