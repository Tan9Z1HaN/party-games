extends Control

## 应用外壳：主菜单 -> 大厅 -> 对局。
##
## Room 是本场景的子节点，路径固定为 /root/Main/Room ——
## 联网那条链路全靠它，改动节点树形状会让 RPC 静默失效。

const GAME_SCENE := "res://games/draw_guess/main.tscn"

## 大厅里暂时只用一个固定配置。等这一版跑通了再加配置界面。
const DEFAULT_CONFIG := {
	"rounds": 3,
	"round_seconds": 80,
	"difficulty": 2,
	"hints": true,
}

var _room: Room
var _menu: PanelContainer
var _lobby: PanelContainer
var _game_screen: Control = null

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
var _rounds_input: OptionButton
var _seconds_input: OptionButton


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
	_show_menu()


# ---------------------------------------------------------------- 界面搭建

func _build_menu() -> void:
	_menu = PanelContainer.new()
	_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu.add_theme_stylebox_override("panel", LightTheme.panel_style())
	add_child(_menu)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 16)

	box.add_child(LightTheme.label(tr("聚会游戏"), 112))

	box.add_child(LightTheme.label(tr("你的昵称"), 42))
	_nickname = LineEdit.new()
	_nickname.text = "玩家"
	_nickname.add_theme_font_size_override("font_size", 48)
	_nickname.custom_minimum_size = Vector2(0, 92)
	box.add_child(_nickname)

	box.add_child(LightTheme.label(tr("创建房间"), 42))
	var host_button := LightTheme.button(tr("我是房主，建房"), 52)
	host_button.pressed.connect(_on_host_pressed)
	box.add_child(host_button)

	box.add_child(LightTheme.label(tr("加入房间（填房主屏幕上的地址）"), 42))
	var address_row := HBoxContainer.new()
	address_row.add_theme_constant_override("separation", 10)
	_ip = LineEdit.new()
	_ip.placeholder_text = tr("192.168.1.5")
	_ip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ip.add_theme_font_size_override("font_size", 48)
	_ip.custom_minimum_size = Vector2(0, 92)
	address_row.add_child(_ip)
	_port = LineEdit.new()
	_port.text = str(Protocol.GAME_PORT)
	_port.add_theme_font_size_override("font_size", 48)
	_port.custom_minimum_size = Vector2(200, 92)
	address_row.add_child(_port)
	box.add_child(address_row)

	var join_button := LightTheme.button(tr("加入"), 52)
	join_button.pressed.connect(_on_join_pressed)
	box.add_child(join_button)

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

	# 房主在这里定回合数和每回合时长，定完立刻同步给所有人
	_lobby_settings = VBoxContainer.new()
	_lobby_settings.add_theme_constant_override("separation", 8)

	_lobby_settings.add_child(LightTheme.label(tr("回合数"), 34))
	_rounds_input = OptionButton.new()
	# 0 = 按人数，够让每个人都当一次画手。默认就选它，
	# 否则默认 3 回合、4 个人的时候会有一个人永远轮不到。
	_rounds_input.add_item(tr("每人一次"), 0)
	for n in [1, 2, 3, 4, 5, 6, 8, 10]:
		_rounds_input.add_item(tr("%d 回合") % n, n)
	_rounds_input.select(0)
	_rounds_input.custom_minimum_size = Vector2(0, 80)
	_rounds_input.add_theme_font_size_override("font_size", 34)
	_rounds_input.item_selected.connect(func(_i): _push_config())
	_lobby_settings.add_child(_rounds_input)

	_lobby_settings.add_child(LightTheme.label(tr("每回合时长"), 34))
	_seconds_input = OptionButton.new()
	for seconds in [40, 60, 80, 100, 120, 150]:
		_seconds_input.add_item(tr("%d 秒") % seconds, seconds)
	_seconds_input.select(2)                 # 80 秒
	_seconds_input.custom_minimum_size = Vector2(0, 80)
	_seconds_input.add_theme_font_size_override("font_size", 34)
	_seconds_input.item_selected.connect(func(_i): _push_config())
	_lobby_settings.add_child(_seconds_input)

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

func _show_menu(message := "") -> void:
	if _game_screen != null:
		_game_screen.queue_free()
		_game_screen = null
	_menu.visible = true
	_lobby.visible = false
	_menu_status.text = message
	LightTheme.present(_menu)


## 装载对局界面。单机和联机用的是同一个场景：
## 单机进来后会停在自己的设置页（选人数、回合数那些），
## 联机则由 setup_networked() 直接进入对局。
func _open_game_screen() -> bool:
	_menu.visible = false
	_lobby.visible = false
	if _game_screen != null:
		_game_screen.queue_free()
		_game_screen = null

	var scene := load(GAME_SCENE)
	if scene == null:
		_on_connection_lost(tr("加载游戏界面失败：%s") % GAME_SCENE)
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
	var port := _room.host_room(_nickname.text, Protocol.MAX_PLAYERS)
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
	_room.join_room(address, int(_port.text), _nickname.text)


func _on_start_pressed() -> void:
	_room.set_game("draw_guess", _current_config())
	if not _room.start_game():
		_lobby_status.text = tr("开局失败：至少要两个人")


## 回合数选「每人一次」时按当前人数算。放在开局前算，
## 因为人数是随时会变的，选中的那一刻算出来会过期。
func _current_config() -> Dictionary:
	var rounds := _rounds_input.get_selected_id()
	if rounds <= 0:
		rounds = maxi(1, _room.get_player_count())
	return {
		"rounds": rounds,
		"round_seconds": _seconds_input.get_selected_id(),
		"difficulty": 2,
		"hints": true,
	}


func _push_config() -> void:
	if _room.is_host():
		_room.set_game("draw_guess", _current_config())
		_lobby_status.text = _config_text()


func _config_text() -> String:
	var config := _current_config()
	return tr("回合数 %d · 每回合 %d 秒") % [int(config["rounds"]), int(config["round_seconds"])]


func _on_joined() -> void:
	if not _lobby.visible:
		_show_lobby()


func _on_refused(reason: int) -> void:
	var text := tr("连接被拒绝")
	match reason:
		Protocol.Refuse.VERSION_MISMATCH: text = tr("对方版本不一致，双方都得是最新版")
		Protocol.Refuse.ROOM_FULL: text = tr("房间满了")
		Protocol.Refuse.GAME_IN_PROGRESS: text = tr("对方已经开局了")
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
	# 设置项只有房主能改；其他人看一行摘要就行
	_lobby_settings.visible = is_host and not bool(state["started"])
	if is_host:
		if _lobby_status.text.is_empty():
			_lobby_status.text = tr("把上面的地址告诉朋友，让他们在首页填进去")
	else:
		_lobby_status.text = _config_text()


func address_of_host(state: Dictionary) -> String:
	for entry in state["players"]:
		if int(entry["peer_id"]) == int(state["host_id"]):
			return String(entry["name"])
	return "?"


func _on_game_started(game_id: String, config: Dictionary) -> void:
	if not _open_game_screen():
		return
	_game_screen.setup_networked(_room, _room.get_state()["players"], config)


func _on_game_exit_requested() -> void:
	var was_online := _room.is_in_room()
	_room.leave_room()
	_show_menu(tr("已退出房间。再玩一局请重新建房或加入。") if was_online else "")
