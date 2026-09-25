extends Control

## 应用外壳：主菜单 -> 大厅 -> 对局。
##
## Room 是本场景的子节点，路径固定为 /root/Main/Room ——
## 联网那条链路全靠它，改动节点树形状会让 RPC 静默失效。

## 开屏页上竖排的四个字，以及右下角署名的名字。改这两行就能换。
const SPLASH_TITLE := "聚在一起"
const AUTHOR_NAME := "Tan9Z1HaN"
## 头像。想换头像直接替换这张图就行，路径不用动。
const AVATAR_PATH := "res://头像.jpg"

## 开屏停留多久（不含淡入淡出）。点一下可以提前跳过。
const SPLASH_SECONDS := 1.2
## 开屏最多显示这么久。收场是一步一步 await 的，其中任何一步卡住
## （掉帧、切后台、tween 被打断）都会让开屏一直挡在屏幕上——
## 那是"打不开应用"级别的故障，所以压一道保险丝：超时直接收掉。
const SPLASH_MAX_SECONDS := 6.0

## 竖排时每个字占的方块，也是行距
const TITLE_CHAR_BOX := 205.0
const TITLE_CHAR_SIZE := 175
## 收场时把竖排收成横排的缩放。四个字横过来比竖着宽得多，缩一点才不会顶出屏幕。
const WORDMARK_SCALE := 0.72
## 「聚」往左上平移多少。它先走到横排第一个字的位置，其余三个再跟着出现。
const WORDMARK_SHIFT := Vector2(-70.0, -90.0)
## 主界面左上角那行横排字的位置，**绝对坐标**（跟菜单内容区的 44 边距无关）。
##
## 开屏收场的落点就是它。两边都从这个常量推，谁也不去读谁的运行时坐标——
## 主界面在开屏期间是隐藏的，布局不保证已经算过，读出来会偏，
## 表现就是"开屏那张字和主界面那张没对齐"。
const WORDMARK_HOME := Vector2(68.0, 60.0)

const SPLASH_BG := Color(0.97, 0.97, 0.97)
const SPLASH_INK := Color(0.07, 0.07, 0.07)
## 头像框的边长和圆角。圆角数值要跟 ROUNDED_RADIUS 对得上，见那边说明。
const AVATAR_FRAME := 360.0
const AVATAR_RADIUS_PX := 62.0
const AVATAR_BORDER := 5
const ROUNDED_SHADER := preload("res://core/ui/rounded.gdshader")

## 关于作者页里的 GitHub 地址。点一下会用系统浏览器打开。
const AUTHOR_URL := "https://github.com/Tan9Z1HaN"

var _room: Room
var _picker: PanelContainer
var _menu: PanelContainer
var _lobby: PanelContainer
var _splash: PanelContainer
var _splash_tween: Tween
var _splash_divider: ColorRect
var _splash_right: VBoxContainer
var _splash_deadline := 0
var _splash_stage: Control
## 开屏那四个字。**故意不放进容器里**：收场时要让每个字各走各的，
## 容器会一直把它们按布局摆回去，动画根本推不动。
var _title_chars: Array = []
## 主界面左上角那行横排的应用名。开屏收场就落在它身上。
var _wordmark_chars: Array = []
var _wordmark_stage: Control
var _about: PanelContainer
var _game_screen: Control = null

var _menu_game: Label
var _host_label: Label
var _host_button: Button
var _solo_button: Button
var _join_label: Label
var _join_button: Button
var _address_row: HBoxContainer
var _nickname: LineEdit
var _ip: LineEdit
var _port: LineEdit
var _menu_status: Label

var _lobby_title: Label
var _lobby_address: Label
var _lobby_players: VBoxContainer
var _lobby_start: Button
var _lobby_status: Label
var _lobby_settings: VBoxContainer
var _lobby_game_label: Label
var _config_box: VBoxContainer

## 当前选中的游戏 id。第一个注册的游戏就是默认值。
var _selected_game := ""

## 配置项：id -> { item, caption, widget }。
## 存 item 和 caption 是为了改值时能重新拼标题文字（"回合数：3"）。
var _config_rows := {}


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = LightTheme.build()
	add_child(LightTheme.backdrop())

	_room = $Room
	_room.joined.connect(_on_joined)
	_room.refused.connect(_on_refused)
	_room.connection_lost.connect(_on_connection_lost)
	_room.state_changed.connect(_on_state_changed)
	_room.game_started.connect(_on_game_started)

	_fit_window_to_screen()
	_build_menu()
	_build_lobby()
	_build_picker()
	_build_about()
	_build_splash()
	_install_back_handler()
	_show_picker()
	_show_splash()


# ---------------------------------------------------------------- 返回键

## 开屏的保险丝。正常走完是 3 秒出头；超过 SPLASH_MAX_SECONDS 还没收掉，
## 说明动画卡住了，直接收——绝不能让开屏挡住整个应用。
func _process(_delta: float) -> void:
	# 主界面那行横排字的显示跟着"选游戏"那一屏走。放在这里一处同步，
	# 就不会因为漏改某个入口（菜单、大厅、对局）而残留在别的界面上。
	if _wordmark_stage != null and _picker != null:
		_wordmark_stage.visible = _picker.visible
	if _splash == null or not _splash.visible:
		return
	if Time.get_ticks_msec() > _splash_deadline:
		push_warning("开屏超时，强制收起")
		dismiss_splash(true)


## 把返回键接上。
##
## 引擎默认的行为是**直接退出应用**（application/config/quit_on_go_back），
## 在手机上按一下返回键游戏就没了，非常容易误触。现在那一项关掉了，
## 改成这里自己处理：沿界面栈往回走一层。
##
## 接的是 Window 自带的 go_back_requested 信号——它只在根 Window 上发，
## 场景里的节点收不到，所以这里用 get_window() 而不是自己造一套。
func _install_back_handler() -> void:
	var window := get_window()
	if window == null:
		return
	if not window.go_back_requested.is_connected(_on_back_requested):
		window.go_back_requested.connect(_on_back_requested)


func _on_back_requested() -> void:
	if not go_back():
		# 已经在第一屏了，再按一次才真的退出
		get_tree().quit()


## 往回退一层。返回 false 表示已经在最外层，没得退了。
##
## 界面栈：选游戏 → 菜单 → 大厅 → 对局。
## 单机没有大厅那一步，对局按返回直接回菜单。
func go_back() -> bool:
	if _splash != null and _splash.visible:
		# 开屏还没走完就按返回：跳过它，而不是退出应用
		dismiss_splash(true)
		return true
	if _about != null and _about.visible:
		_hide_about()
		return true
	if _game_screen != null:
		# 对局中返回 = 退出这一局。联机时连房间一起退，不然房主那边
		# 会留着一个已经走人的玩家。
		_on_game_exit_requested()
		return true
	if _lobby.visible:
		_room.leave_room()
		_show_menu(tr("已退出房间。再玩一局请重新建房或加入。"))
		return true
	if _menu.visible:
		_show_picker()
		return true
	return false


## 桌面上没有返回键，用 Esc（ui_cancel）走同一条路，
## 方便对着返回逻辑调试，行为也跟手机一致。
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	get_viewport().set_input_as_handled()
	_on_back_requested()


## 电脑上窗口默认是 540x960。屏幕（或笔记本的小屏）装不下这么高时，
## 系统会把窗口底部截到屏幕外——玩家看到的就是「屏幕显示不全」，
## 底下一排按钮永远点不到。启动时按可用区域等比缩一下。
##
## 只在桌面上做：手机上窗口本来就是全屏，缩了反而会露出黑边。
func _fit_window_to_screen() -> void:
	if not OS.has_feature("pc"):
		return
	var window := get_window()
	if window == null:
		return
	var current := window.size
	var usable := DisplayServer.screen_get_usable_rect(
		DisplayServer.window_get_current_screen()).size
	if current.x <= 0 or current.y <= 0 or usable.x <= 0 or usable.y <= 0:
		return
	var factor := minf(1.0,
		minf(float(usable.x) / float(current.x), float(usable.y) / float(current.y)))
	if factor < 0.999:
		window.size = Vector2i(int(float(current.x) * factor),
			int(float(current.y) * factor))


# ---------------------------------------------------------------- 界面搭建

## 开屏：左边竖排应用名，中间一条竖线，右边头像框加署名。
## 版式照设计稿来——四个字是**竖着一个一个排**的，不是横排。
##
## 它盖在最上面，底下的「玩什么」照常先建好；淡出之后直接就是那一屏，
## 中间不用切换场景。
func _build_splash() -> void:
	_splash = PanelContainer.new()
	_splash.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = SPLASH_BG
	_splash.add_theme_stylebox_override("panel", style)
	add_child(_splash)
	# 点一下直接进应用，不用干等
	_splash.gui_input.connect(func(event: InputEvent):
		if (event is InputEventMouseButton and event.pressed) \
				or (event is InputEventScreenTouch and event.pressed):
			dismiss_splash())

	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_splash.add_child(center)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 60)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(row)

	# 左：竖排的四个字。用一个固定尺寸的舞台手动摆位——
	# 收场时要把它们排成横排，容器布局会一直跟动画打架。
	var stage := Control.new()
	stage.custom_minimum_size = Vector2(TITLE_CHAR_BOX,
		TITLE_CHAR_BOX * float(SPLASH_TITLE.length()))
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(stage)
	_splash_stage = stage

	_title_chars.clear()
	var line := 0
	for character in SPLASH_TITLE:
		var label := LightTheme.label(character, TITLE_CHAR_SIZE)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.size = Vector2(TITLE_CHAR_BOX, TITLE_CHAR_BOX)
		label.position = Vector2(0.0, TITLE_CHAR_BOX * float(line))
		label.add_theme_color_override("font_color", SPLASH_INK)
		stage.add_child(label)
		_title_chars.append(label)
		line += 1

	# 中：一条竖线。高度比四个字略短一点，两头留白
	var divider := ColorRect.new()
	divider.color = SPLASH_INK
	divider.custom_minimum_size = Vector2(5, 700)
	divider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(divider)
	_splash_divider = divider

	# 右：头像框 + 署名
	var right := VBoxContainer.new()
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	right.add_theme_constant_override("separation", 40)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(right)
	right.add_child(_build_avatar_frame())

	var made_by := LightTheme.label("Made by %s" % AUTHOR_NAME, 40)
	made_by.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	made_by.add_theme_color_override("font_color", SPLASH_INK)
	right.add_child(made_by)
	_splash_right = right


## 圆角黑框里的头像。框里的图被 shader 裁成圆角，
## 不然直角图片的四角会从圆角边框里探出来。
##
## 尺寸和圆角都带默认值：开屏用大的，关于作者页用小的，同一份代码。
func _build_avatar_frame(size := AVATAR_FRAME, radius_px := AVATAR_RADIUS_PX,
		border := AVATAR_BORDER) -> Control:
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(size, size)
	frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = SPLASH_BG
	style.set_corner_radius_all(int(radius_px))
	style.border_color = SPLASH_INK
	style.border_width_top = border
	style.border_width_bottom = border
	style.border_width_left = border
	style.border_width_right = border
	# 图片缩到边框里面，否则会被边框压掉一圈
	for side in ["top", "bottom", "left", "right"]:
		style.set("content_margin_" + side, float(border))
	frame.add_theme_stylebox_override("panel", style)

	var avatar := TextureRect.new()
	avatar.texture = load(AVATAR_PATH)
	avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new()
	material.shader = ROUNDED_SHADER
	# shader 里的半径单位是"半边长的比例"，所以要按框内实际边长换算
	var inner := size - border * 2.0
	var radius := radius_px - border
	material.set_shader_parameter("radius", radius / (inner * 0.5))
	avatar.material = material
	frame.add_child(avatar)
	return frame


## 开屏淡入，停一会儿，再淡出到「玩什么」。点一下可以提前跳过。
func _show_splash() -> void:
	if _splash == null:
		return
	# 主界面先藏起来，等开屏快走完再让它淡入。
	# 直接把它晾在开屏底下的话，开屏淡出只是"揭开一层膜"——
	# 底下那屏纹丝不动地等在那儿，看着像贴图；让它自己出场才像衔接。
	_picker.visible = false
	_splash.visible = true
	_splash.modulate.a = 0.0
	_splash_deadline = Time.get_ticks_msec() + int(SPLASH_MAX_SECONDS * 1000.0)
	_reset_splash()
	_splash_tween = create_tween()
	_splash_tween.tween_property(_splash, "modulate:a", 1.0, 0.3)
	_splash_tween.tween_interval(SPLASH_SECONDS)
	_splash_tween.tween_callback(_play_splash_outro)


## 把开屏恢复成刚出场的样子。收场动画会改动字的位置、透明度，
## 重放（测试会重放）之前得先摆回去。
func _reset_splash() -> void:
	for i in _title_chars.size():
		var label: Control = _title_chars[i]
		label.position = Vector2(0.0, TITLE_CHAR_BOX * float(i))
		label.scale = Vector2.ONE
		label.modulate.a = 1.0
	if _splash_right != null:
		_splash_right.modulate.a = 1.0
	if _splash_divider != null:
		_splash_divider.modulate.a = 1.0


## 开屏的收场。顺序是设计稿定的：
##   头像那块先消失 → 只剩「聚」→ 聚往左上平移 →
##   「在一起」跟着出现，排成横排 → 停一拍，整屏淡出进主界面
##
## 每一步之后都看一眼开屏还在不在：中途被点掉（或者按了返回）就直接收工，
## 别让已经藏起来的开屏继续动。
func _play_splash_outro() -> void:
	if _splash == null or not _splash.visible:
		return

	# 1. 图像先走：头像框和署名，连中间那条竖线一起——
	#    竖线本来就是"左右两块"的分隔，右边没了它也没意义
	var go_image := create_tween()
	go_image.set_parallel(true)
	go_image.tween_property(_splash_right, "modulate:a", 0.0, 0.28)
	go_image.tween_property(_splash_divider, "modulate:a", 0.0, 0.28)
	await go_image.finished
	if not _splash.visible:
		return

	# 2. 「在一起」三个字淡出，只剩「聚」
	var go_tail := create_tween()
	go_tail.set_parallel(true)
	for i in range(1, _title_chars.size()):
		go_tail.tween_property(_title_chars[i], "modulate:a", 0.0, 0.2)
	await go_tail.finished
	if not _splash.visible:
		return

	# 3. 「聚」往左上平移，落到主界面那行横排字第一个字的位置上
	var landing := _wordmark_landing()
	if landing.size() != _title_chars.size():
		return
	var move := create_tween()
	move.set_parallel(true)
	move.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	move.tween_property(_title_chars[0], "position", landing[0], 0.42)
	move.tween_property(_title_chars[0], "scale",
		Vector2(WORDMARK_SCALE, WORDMARK_SCALE), 0.42)
	await move.finished
	if not _splash.visible:
		return

	# 4. 「在一起」在它右边逐个出现，像把名字写出来。落点同样对齐主界面那张。
	#    Label 的缩放原点是左上角，位置直接给"目标左上角"就行。
	var appear := create_tween()
	appear.set_parallel(true)
	for i in range(1, _title_chars.size()):
		var label: Control = _title_chars[i]
		label.position = landing[i]
		label.scale = Vector2(WORDMARK_SCALE, WORDMARK_SCALE)
		appear.tween_property(label, "modulate:a", 1.0, 0.26) \
			.set_delay(0.08 * float(i - 1))
	await appear.finished
	if not _splash.visible:
		return

	var hold := create_tween()
	hold.tween_interval(0.12)
	await hold.finished
	if not _splash.visible:
		return

	# 5. 交接。主界面那边**也有一行一模一样的字**，位置由 _wordmark_landing()
	#    对齐过，所以两张在同一处交叉淡入淡出，看起来就是字留在了主界面上。
	#    这里主界面只淡入、不缩放：缩放会让它那行字跟着缩，跟开屏这张错开，
	#    交叉的那几帧就会出现重影。
	var out := create_tween()
	out.set_parallel(true)
	out.tween_property(_splash, "modulate:a", 0.0, 0.26)
	out.tween_callback(_present_picker_from_splash)
	await out.finished
	dismiss_splash(true)


## 开屏那四个字要落在主界面横排字的位置上，返回的是**开屏舞台坐标系**里的坐标。
##
## 两张字是一样的字号和缩放，所以只要左上角对齐，渲染出来就是完全重合的。
##
## **不读主界面节点的坐标**：那一屏在开屏期间是隐藏的，布局不保证已经算过，
## 读出来会偏。两边都从 WORDMARK_HOME 这个常量推，才不会对不上。
func _wordmark_landing() -> Array:
	var out: Array = []
	if _splash_stage == null:
		return out
	var to_stage := _splash_stage.get_global_transform().affine_inverse()
	var to_app := get_global_transform()
	var step := TITLE_CHAR_BOX * WORDMARK_SCALE
	for i in SPLASH_TITLE.length():
		out.append(to_stage * (to_app * (WORDMARK_HOME + Vector2(step * float(i), 0.0))))
	return out


## 从开屏交接过来时，主界面只淡入，不做 LightTheme.present 那个缩放——
## 缩放会把主界面那行横排字一起缩小，跟开屏那张错开位置，交叉时出现重影。
func _present_picker_from_splash() -> void:
	_picker.visible = true
	_picker.pivot_offset = Vector2.ZERO
	_picker.scale = Vector2.ONE
	_picker.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(_picker, "modulate:a", 1.0, 0.26)


## 主界面的出场：淡入 + 从 0.97 轻轻放大到 1。
func _present_picker() -> void:
	_picker.visible = true
	LightTheme.present(_picker, 0.32)


## 收起开屏。测试和截图工具直接调它，免得每张图都等两秒。
##
## instant 为 true 时主界面直接就位，不走淡入——截图工具要的是稳定的画面，
## 不该跟动画抢时间。
func dismiss_splash(instant := false) -> void:
	if _splash == null or not _splash.visible:
		return
	if _splash_tween != null and _splash_tween.is_valid():
		_splash_tween.kill()
	_splash_tween = null
	_splash.visible = false
	if instant:
		_picker.visible = true
		_picker.modulate.a = 1.0
		_picker.scale = Vector2.ONE
	else:
		_present_picker()


## 第一屏：玩什么。游戏是入口级别的选择，不藏在房间里——
## 你画我猜和 UNO 本来就是两个不同的游戏，混在一个房间配置里只会让人困惑。
func _build_picker() -> void:
	_picker = PanelContainer.new()
	_picker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_picker.add_theme_stylebox_override("panel", LightTheme.panel_style())
	add_child(_picker)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 24)
	# 名字由开屏负责，这一屏只放选择，不再重复标题。
	# 上下各留一个弹性空档：游戏列表大致居中，「关于作者」落到最下面。
	box.add_child(_spacer())

	for entry in GamesCatalog.entries():
		var id := String(entry["id"])
		var button := LightTheme.button("%s　（%d~%d 人 · 约 %d 分钟）" % [
			entry["name"], int(entry["min_players"]),
			int(entry["max_players"]), int(entry["est_minutes"])], 44)
		button.custom_minimum_size = Vector2(0, 130)
		button.pressed.connect(func(): _on_game_selected(id))
		box.add_child(button)

	box.add_child(_spacer())

	# 小一号的次要入口，贴在最下面，别跟游戏选择抢注意力
	var about_row := HBoxContainer.new()
	about_row.alignment = BoxContainer.ALIGNMENT_CENTER
	var about := LightTheme.button(tr("关于作者"), 28)
	about.custom_minimum_size = Vector2(240, 72)
	about.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	about.pressed.connect(_show_about)
	about_row.add_child(about)
	box.add_child(about_row)

	_picker.add_child(box)
	_build_wordmark()


## 主界面左上角那行横排的应用名。
##
## 它和开屏收场用的是同一套字（同字号、同缩放、同样的字距），
## 位置由 WORDMARK_HOME 定死——所以开屏把那四个字挪过来之后，
## 两者是**完全重合**的，交接看不出接缝。
func _build_wordmark() -> void:
	var stage := Control.new()
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 挂在应用根节点上而不是菜单面板里：菜单面板是容器，会把子节点的位置
	# 按自己的内容区强制摆一遍，那样"绝对位置"就不作数了。
	# 显示与否在 _process 里跟着选游戏那一屏同步。
	add_child(stage)
	_wordmark_stage = stage

	_wordmark_chars.clear()
	var step := TITLE_CHAR_BOX * WORDMARK_SCALE
	var index := 0
	for character in SPLASH_TITLE:
		var label := LightTheme.label(character, TITLE_CHAR_SIZE)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.size = Vector2(TITLE_CHAR_BOX, TITLE_CHAR_BOX)
		label.scale = Vector2(WORDMARK_SCALE, WORDMARK_SCALE)
		label.position = WORDMARK_HOME + Vector2(step * float(index), 0.0)
		label.add_theme_color_override("font_color", SPLASH_INK)
		stage.add_child(label)
		_wordmark_chars.append(label)
		index += 1


## 占位用的弹性空档。VBoxContainer 里靠它把内容顶到两端。
func _spacer() -> Control:
	var node := Control.new()
	node.size_flags_vertical = Control.SIZE_EXPAND_FILL
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return node


## 关于作者。头像、名字、GitHub 地址，地址做成按钮可以直接点开。
##
## 铺满整屏的半透明底：点空白处就能关掉，不用非去找关闭按钮。
func _build_about() -> void:
	_about = PanelContainer.new()
	_about.set_anchors_preset(Control.PRESET_FULL_RECT)
	var backdrop := StyleBoxFlat.new()
	backdrop.bg_color = Color(0.1, 0.1, 0.15, 0.45)
	_about.add_theme_stylebox_override("panel", backdrop)
	_about.visible = false
	add_child(_about)
	_about.gui_input.connect(func(event: InputEvent):
		if (event is InputEventMouseButton and event.pressed) \
				or (event is InputEventScreenTouch and event.pressed):
			_hide_about())

	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_about.add_child(center)

	var card := PanelContainer.new()
	# 这里必须是不透明的卡片：LightTheme.panel_style() 是半透明的玻璃面板，
	# 当对话框用的话底下的游戏按钮会透上来
	var card_style := StyleBoxFlat.new()
	card_style.bg_color = Color(1, 1, 1)
	card_style.set_corner_radius_all(28)
	card_style.border_width_top = 2
	card_style.border_width_bottom = 2
	card_style.border_width_left = 2
	card_style.border_width_right = 2
	card_style.border_color = LightTheme.GLASS_BORDER
	card_style.shadow_color = LightTheme.GLASS_SHADOW
	card_style.shadow_size = 12
	card_style.shadow_offset = Vector2(0, 4)
	card_style.content_margin_left = 48.0
	card_style.content_margin_right = 48.0
	card_style.content_margin_top = 40.0
	card_style.content_margin_bottom = 40.0
	card.add_theme_stylebox_override("panel", card_style)
	# 卡片自己要吃掉点击，否则点卡片也会被当成"点空白"关掉
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(card)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 28)
	card.add_child(box)

	var title := LightTheme.label(tr("关于作者"), 44)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	box.add_child(_build_avatar_frame(240.0, 42.0, 4))
	var who := LightTheme.label(AUTHOR_NAME, 52)
	who.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(who)

	var link := LightTheme.button(AUTHOR_URL, 34)
	link.pressed.connect(func(): OS.shell_open(AUTHOR_URL))
	box.add_child(link)

	var close := LightTheme.button(tr("关闭"), 34)
	close.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	close.custom_minimum_size = Vector2(240, 72)
	close.pressed.connect(_hide_about)
	box.add_child(close)


func _show_about() -> void:
	_about.visible = true
	LightTheme.present(_about, 0.18)


func _hide_about() -> void:
	_about.visible = false


func _on_game_selected(id: String) -> void:
	_selected_game = id
	_rebuild_config()
	_show_menu()


func _build_menu() -> void:
	_menu = PanelContainer.new()
	_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu.add_theme_stylebox_override("panel", LightTheme.panel_style())
	add_child(_menu)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 16)

	_menu_game = LightTheme.label("", 96)
	box.add_child(_menu_game)

	var switch_game := LightTheme.button(tr("换一个游戏"), 30)
	switch_game.pressed.connect(_show_picker)
	box.add_child(switch_game)

	box.add_child(LightTheme.label(tr("你的昵称"), 42))
	_nickname = LineEdit.new()
	_nickname.text = "玩家"
	_nickname.add_theme_font_size_override("font_size", 48)
	_nickname.custom_minimum_size = Vector2(0, 92)
	box.add_child(_nickname)

	_host_label = LightTheme.label(tr("创建房间"), 42)
	box.add_child(_host_label)
	_host_button = LightTheme.button(tr("我是房主，建房"), 52)
	_host_button.pressed.connect(_on_host_pressed)
	box.add_child(_host_button)

	_join_label = LightTheme.label(tr("加入房间（填房主屏幕上的地址）"), 42)
	box.add_child(_join_label)
	_address_row = HBoxContainer.new()
	_address_row.add_theme_constant_override("separation", 10)
	_ip = LineEdit.new()
	_ip.placeholder_text = tr("192.168.1.5")
	_ip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ip.add_theme_font_size_override("font_size", 48)
	_ip.custom_minimum_size = Vector2(0, 92)
	_address_row.add_child(_ip)
	_port = LineEdit.new()
	_port.text = str(Protocol.GAME_PORT)
	_port.add_theme_font_size_override("font_size", 48)
	_port.custom_minimum_size = Vector2(200, 92)
	_address_row.add_child(_port)
	box.add_child(_address_row)

	_join_button = LightTheme.button(tr("加入"), 52)
	_join_button.pressed.connect(_on_join_pressed)
	box.add_child(_join_button)

	# 单机对电脑。放在最后：联机才是这个 App 的主线，单机是没网时的退路。
	# 有隐藏手牌的游戏（比如 UNO）只能这样单机玩，同屏热座会让所有人
	# 看到彼此的手牌。
	_solo_button = LightTheme.button(tr("单机试玩（对电脑）"), 52)
	_solo_button.pressed.connect(_on_solo_pressed)
	box.add_child(_solo_button)

	_menu_status = LightTheme.label("", 30)
	_menu_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_menu_status)

	_menu.add_child(box)


func _build_lobby() -> void:
	_lobby = PanelContainer.new()
	_lobby.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lobby.add_theme_stylebox_override("panel", LightTheme.panel_style())
	add_child(_lobby)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	box.alignment = BoxContainer.ALIGNMENT_CENTER

	_lobby_title = LightTheme.label("", 56)
	box.add_child(_lobby_title)

	_lobby_address = LightTheme.label("", 48)
	_lobby_address.add_theme_color_override("font_color", LightTheme.INK_ACCENT)
	box.add_child(_lobby_address)

	var copy := LightTheme.button(tr("复制地址发给朋友"), 36)
	copy.pressed.connect(func():
		DisplayServer.clipboard_set(_lobby_address.text))
	box.add_child(copy)

	box.add_child(LightTheme.label(tr("玩家"), 36))
	_lobby_players = VBoxContainer.new()
	_lobby_players.add_theme_constant_override("separation", 6)
	box.add_child(_lobby_players)

	# 玩什么、怎么配，全部由注册表和游戏自己声明的 schema 决定。
	# 这个文件里不该出现具体游戏的字段名。
	_lobby_settings = VBoxContainer.new()
	_lobby_settings.add_theme_constant_override("separation", 10)

	_lobby_game_label = LightTheme.label("", 34)
	_lobby_settings.add_child(_lobby_game_label)

	_config_box = VBoxContainer.new()
	_config_box.add_theme_constant_override("separation", 12)
	_lobby_settings.add_child(_config_box)
	_rebuild_config()

	box.add_child(_lobby_settings)

	_lobby_start = LightTheme.button(tr("开始游戏"), 44)
	_lobby_start.pressed.connect(_on_start_pressed)
	box.add_child(_lobby_start)

	var leave := LightTheme.button(tr("离开房间"), 34)
	leave.pressed.connect(func():
		_room.leave_room()
		_show_menu(tr("已离开房间")))
	box.add_child(leave)

	_lobby_status = LightTheme.label("", 30)
	_lobby_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_lobby_status)

	_lobby.add_child(box)


# ---------------------------------------------------------------- 流程

## 按当前游戏的 get_config_schema() 铺一遍配置控件。
## 加一款新游戏时这个函数一个字都不用改。
func _rebuild_config() -> void:
	LightTheme.clear_children(_config_box)
	_config_rows.clear()
	# 还没选游戏时什么都不建。大厅是先于第一屏建好的，
	# 少了这道守卫，应用一启动就会拿空 id 去查 schema。
	if _selected_game.is_empty():
		return
	for item in GamesCatalog.schema_for(_selected_game):
		var id := String(item["id"])
		var caption := LightTheme.label("", 28)
		var widget := _make_config_widget(item)
		if widget == null:
			push_warning("配置项类型不支持：%s" % String(item.get("type", "?")))
			continue
		_config_rows[id] = {"item": item, "caption": caption, "widget": widget}
		_config_box.add_child(caption)
		_config_box.add_child(widget)
	_refresh_captions()


## bool 用开关按钮（不用 CheckButton：它的勾选图标来自默认深色主题，
## 在浅色底上几乎看不见），int 用滑杆，enum 用下拉。
func _make_config_widget(item: Dictionary) -> Control:
	match String(item.get("type", "")):
		"bool":
			var toggle := LightTheme.button("", 28)
			toggle.toggle_mode = true
			toggle.button_pressed = bool(item["default"])
			toggle.pressed.connect(_on_config_changed)
			return toggle
		"int":
			var slider := HSlider.new()
			slider.min_value = float(item["min"])
			slider.max_value = float(item["max"])
			slider.step = 1
			slider.value = float(item["default"])
			slider.custom_minimum_size = Vector2(0, 48)
			slider.value_changed.connect(func(_v): _on_config_changed())
			return slider
		"enum":
			var picker := OptionButton.new()
			picker.custom_minimum_size = Vector2(0, 72)
			picker.add_theme_font_size_override("font_size", 30)
			for option in item["options"]:
				picker.add_item(String(option["label"]))
				picker.set_item_metadata(picker.item_count - 1, option["value"])
				if option["value"] == item["default"]:
					picker.select(picker.item_count - 1)
			picker.item_selected.connect(func(_i): _on_config_changed())
			return picker
	return null


func _on_config_changed() -> void:
	_refresh_captions()
	_push_config()


func _refresh_captions() -> void:
	for id in _config_rows:
		var row: Dictionary = _config_rows[id]
		var caption: Label = row["caption"]
		var widget: Control = row["widget"]
		var label := String(row["item"]["label"])
		if widget is Button:
			var on_text := tr("开") if (widget as Button).button_pressed else tr("关")
			caption.text = "%s：%s" % [label, on_text]
		elif widget is HSlider:
			caption.text = "%s：%d" % [label, int((widget as HSlider).value)]
		else:
			caption.text = label


func _show_menu(message := "") -> void:
	if _game_screen != null:
		_game_screen.queue_free()
		_game_screen = null
	_picker.visible = false
	_lobby.visible = false
	_menu.visible = true
	_menu_game.text = GamesCatalog.display_name(_selected_game)
	_menu_status.text = message
	# 按游戏自己声明的能力决定显示哪些入口——不靠判断游戏 id
	var entry := _entry_for(_selected_game)
	var online := bool(entry.get("online", true))
	var solo := bool(entry.get("solo", false))
	_host_label.visible = online
	_host_button.visible = online
	_join_label.visible = online
	_address_row.visible = online
	_join_button.visible = online
	_solo_button.visible = solo
	if not online and solo and message.is_empty():
		_menu_status.text = tr("这款还没接联机，先在单机模式试玩")
	LightTheme.present(_menu)


## 回第一屏重选游戏。顺手退掉房间——游戏是入口级选择，
## 换游戏等于换一局，不能带着旧房间走。
func _show_picker() -> void:
	if _game_screen != null:
		_game_screen.queue_free()
		_game_screen = null
	_room.leave_room()
	_picker.visible = true
	_menu.visible = false
	_lobby.visible = false
	LightTheme.present(_picker)


func _entry_for(game_id: String) -> Dictionary:
	for entry in GamesCatalog.entries():
		if String(entry["id"]) == game_id:
			return entry
	return {}


## 单机试玩：不进房间，直接开局对电脑。
func _on_solo_pressed() -> void:
	if not _open_game_screen(_selected_game):
		return
	if _game_screen.has_method("setup_solo"):
		_game_screen.setup_solo(2)
	else:
		push_error("这个游戏没有单机入口：%s" % _selected_game)
		_show_menu(tr("这款游戏还不支持单机试玩"))


## 装载对局界面。单机和联机用的是同一个场景：
## 单机进来后会停在自己的设置页（选人数、回合数那些），
## 联机则由 setup_networked() 直接进入对局。
func _open_game_screen(game_id: String) -> bool:
	_menu.visible = false
	_lobby.visible = false
	if _game_screen != null:
		_game_screen.queue_free()
		_game_screen = null

	var scene_path := GamesCatalog.scene_for(game_id)
	if scene_path.is_empty():
		_on_connection_lost(tr("没有注册这个游戏：%s") % game_id)
		return false
	var scene: PackedScene = load(scene_path)
	if scene == null:
		_on_connection_lost(tr("加载游戏界面失败：%s") % scene_path)
		return false

	_game_screen = scene.instantiate()
	add_child(_game_screen)
	_game_screen.exit_requested.connect(_on_game_exit_requested)
	LightTheme.present(_game_screen)
	return true


func _show_lobby() -> void:
	_menu.visible = false
	_lobby.visible = true
	_refresh_lobby()
	LightTheme.present(_lobby)


func _on_host_pressed() -> void:
	var port := _room.host_room(_nickname.text, Protocol.MAX_PLAYERS, _selected_game)
	if port == 0:
		var code := _room.transport.get_last_host_error()
		var hint := tr("换个端口再试")
		if code == 20:
			hint = tr("系统不让创建网络连接。安卓版请确认导出时开了网络权限；电脑上检查防火墙或安全软件")
		elif code == 32:
			hint = tr("端口被占用了，换个端口再试")
		_menu_status.text = tr("建房失败（错误码 %d）：%s") % [code, hint]
		_port.text = str(Protocol.GAME_PORT)
		return
	_port.text = str(port)
	_show_lobby()


func _on_join_pressed() -> void:
	var address := _ip.text.strip_edges()
	if address.is_empty():
		_menu_status.text = tr("先填房主的 IP 地址")
		return
	_menu_status.text = tr("正在连接 %s ...") % address
	_room.join_room(address, int(_port.text), _nickname.text, _selected_game)


func _on_start_pressed() -> void:
	_room.set_game(_selected_game, _current_config())
	var need := int(GamesCatalog.meta_for(_selected_game).get("min_players", 2))
	if _room.get_player_count() < need:
		_lobby_status.text = tr("%s 至少要 %d 个人") % [
			GamesCatalog.display_name(_selected_game), need]
		return
	if not _room.start_game():
		_lobby_status.text = tr("开局失败")


## 配置全部从控件读回。这里不认识任何具体字段——
## 加一款新游戏时这个函数也不用改。
func _current_config() -> Dictionary:
	var config := GamesCatalog.default_config(_selected_game)
	for id in _config_rows:
		var widget: Control = _config_rows[id]["widget"]
		if widget is Button:
			config[id] = (widget as Button).button_pressed
		elif widget is HSlider:
			config[id] = int((widget as HSlider).value)
		elif widget is OptionButton:
			config[id] = (widget as OptionButton).get_selected_id()
	return config


func _push_config() -> void:
	if _room.is_host():
		_room.set_game(_selected_game, _current_config())
		_lobby_status.text = _config_text()


## 给非房主看的一行摘要。配置项从房间里取，标签从游戏的 schema 取，
## 所以客户端也能正确显示别人选了什么。
func _config_text() -> String:
	var state := _room.get_state()
	var game_id := String(state.get("game_id", _selected_game))
	var config: Dictionary = state.get("config", {})
	var parts := PackedStringArray()
	parts.append(GamesCatalog.display_name(game_id))
	for item in GamesCatalog.schema_for(game_id):
		var value = config.get(item["id"], item["default"])
		parts.append("%s %s" % [String(item["label"]), _format_config_value(item, value)])
	return " · ".join(parts)


func _format_config_value(item: Dictionary, value) -> String:
	match String(item.get("type", "")):
		"bool":
			return tr("开") if value else tr("关")
		"enum":
			for option in item["options"]:
				if option["value"] == value:
					return String(option["label"])
			return str(value)
		_:
			return str(value)


func _on_joined() -> void:
	if not _lobby.visible:
		_show_lobby()


func _on_refused(reason: int) -> void:
	var text := tr("连接被拒绝")
	match reason:
		Protocol.Refuse.VERSION_MISMATCH: text = tr("对方版本不一致，双方都得是最新版")
		Protocol.Refuse.ROOM_FULL: text = tr("房间满了")
		Protocol.Refuse.GAME_IN_PROGRESS: text = tr("对方已经开局了")
		Protocol.Refuse.GAME_MISMATCH: text = tr(
			"房主开的不是这款游戏。\n点上面的「换一个游戏」返回重选。")
		Transport.FailReason.TIMEOUT: text = tr(
			"连不上（超时）。\n\n" +
			"1. 确认两台设备在同一个 Wi-Fi 或热点下\n" +
			"2. 如果房主是模拟器：模拟器走的是 NAT 网络，外面的设备连不进去。\n" +
			"   改让真机或电脑当房主，模拟器去加入\n" +
			"3. 电脑当房主时留意 Windows 防火墙有没有放行")
		Transport.FailReason.UNREACHABLE: text = tr("连不上：IP 地址可能填错了")
	_on_connection_lost(text)


func _on_connection_lost(reason: String) -> void:
	var text := tr("和房主的连接断开了")
	if reason != "host_left":
		text = reason
	_show_menu(text)


func _on_state_changed(_state: Dictionary) -> void:
	if _lobby.visible:
		_refresh_lobby()


func _refresh_lobby() -> void:
	var state := _room.get_state()
	var is_host := _room.is_host()

	_lobby_title.text = tr("你是房主") if is_host else tr("已加入房间")

	if is_host:
		var ip := _room.transport.get_local_ip()
		_lobby_address.text = "%s:%d" % [ip if not ip.is_empty() else "?", _room.transport.get_host_port()]
	else:
		_lobby_address.text = tr("房主：%s") % address_of_host(state)

	LightTheme.clear_children(_lobby_players)
	for entry in state["players"]:
		var peer_id := int(entry["peer_id"])
		var suffix := ""
		if peer_id == int(state["host_id"]):
			suffix = tr("（房主）")
		elif peer_id == _room.get_local_id():
			suffix = tr("（你）")
		var ping := _room.transport.get_ping_ms(peer_id)
		var ping_text := "" if ping < 0 else "   %d ms" % ping
		_lobby_players.add_child(
			LightTheme.label("%s%s%s" % [entry["name"], suffix, ping_text], 38))

	_lobby_start.visible = is_host
	var game_id := String(state.get("game_id", _selected_game))
	_lobby_game_label.text = GamesCatalog.display_name(game_id)
	# 配置只有房主能改；其他人看下面那行摘要就行
	_config_box.visible = is_host and not bool(state["started"])
	if is_host:
		var need := int(GamesCatalog.meta_for(game_id).get("min_players", 2))
		var missing := need - _room.get_player_count()
		_lobby_start.disabled = missing > 0
		if missing > 0:
			_lobby_status.text = tr("还差 %d 个人才能开始 %s") % [
				missing, GamesCatalog.display_name(game_id)]
		elif _lobby_status.text.is_empty():
			_lobby_status.text = tr("把上面的地址告诉朋友，让他们在首页填进去")
	else:
		_lobby_status.text = _config_text()


func address_of_host(state: Dictionary) -> String:
	for entry in state["players"]:
		if int(entry["peer_id"]) == int(state["host_id"]):
			return String(entry["name"])
	return "?"


func _on_game_started(game_id: String, config: Dictionary) -> void:
	if not _open_game_screen(game_id):
		return
	_game_screen.setup_networked(_room, _room.get_state()["players"], config)


func _on_game_exit_requested() -> void:
	var was_online := _room.is_in_room()
	_room.leave_room()
	_show_menu(tr("已退出房间。再玩一局请重新建房或加入。") if was_online else "")
