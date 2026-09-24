extends Control

## 应用外壳：主菜单 -> 大厅 -> 对局。
##
## Room 是本场景的子节点，路径固定为 /root/Main/Room ——
## 联网那条链路全靠它，改动节点树形状会让 RPC 静默失效。

var _room: Room
var _picker: PanelContainer
var _menu: PanelContainer
var _lobby: PanelContainer
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

	_build_menu()
	_build_lobby()
	_build_picker()
	_show_picker()


# ---------------------------------------------------------------- 界面搭建

## 第一屏：玩什么。游戏是入口级别的选择，不藏在房间里——
## 你画我猜和 UNO 本来就是两个不同的游戏，混在一个房间配置里只会让人困惑。
func _build_picker() -> void:
	_picker = PanelContainer.new()
	_picker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_picker.add_theme_stylebox_override("panel", LightTheme.panel_style())
	add_child(_picker)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 24)
	box.add_child(LightTheme.label(tr("玩什么"), 96))

	for entry in GamesCatalog.entries():
		var id := String(entry["id"])
		var button := LightTheme.button("%s　（%d~%d 人 · 约 %d 分钟）" % [
			entry["name"], int(entry["min_players"]),
			int(entry["max_players"]), int(entry["est_minutes"])], 44)
		button.custom_minimum_size = Vector2(0, 130)
		button.pressed.connect(func(): _on_game_selected(id))
		box.add_child(button)

	_picker.add_child(box)


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

	# 单机对电脑。有隐藏手牌的游戏（比如 UNO）只能这样单机玩，
	# 同屏热座会让所有人看到彼此的手牌。
	_solo_button = LightTheme.button(tr("单机试玩（对电脑）"), 52)
	_solo_button.pressed.connect(_on_solo_pressed)
	box.add_child(_solo_button)

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
