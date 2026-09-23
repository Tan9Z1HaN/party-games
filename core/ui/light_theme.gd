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
	t.set_stylebox("hover", "PopupMenu", surface_box(SURFACE_PRESSED))

	for tname in ["Button", "OptionButton", "CheckBox", "CheckButton"]:
		t.set_stylebox("normal", tname, surface_box(SURFACE_ALT))
		t.set_stylebox("hover", tname, surface_box(SURFACE))
		t.set_stylebox("pressed", tname, surface_box(SURFACE_PRESSED))
		t.set_stylebox("disabled", tname, surface_box(SURFACE_DISABLED))
		t.set_stylebox("focus", tname, focus_box())

	t.set_stylebox("normal", "LineEdit", surface_box(SURFACE))
	t.set_stylebox("focus", "LineEdit", focus_box())

	return t


static func surface_box(color: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(12)
	box.content_margin_left = 18.0
	box.content_margin_right = 18.0
	box.content_margin_top = 10.0
	box.content_margin_bottom = 10.0
	return box


## 键盘焦点圈：背景全透明只画边，免得盖住正常状态的底色。
static func focus_box() -> StyleBoxFlat:
	var box := surface_box(Color(1, 1, 1, 0.0))
	box.border_width_top = 3
	box.border_width_bottom = 3
	box.border_width_left = 3
	box.border_width_right = 3
	box.border_color = FOCUS_RING
	return box


## 覆盖整屏的面板（菜单、大厅、结算这类）。带内边距，
## 不然内容会顶到屏幕边缘，首字被切、按钮贴边。
static func panel_style() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = SURFACE
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


## 铺一层浅色底。默认清除色是深灰，黑字压上去同样看不清。
static func backdrop() -> ColorRect:
	var rect := ColorRect.new()
	rect.color = BACKDROP
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


static func clear_children(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
