extends SceneTree

## 局域网联机的多进程冒烟测试。
##
## 不要单独跑它——配套脚本 tools/tests/run_net_smoke.ps1 会同时起一个主机
## 和若干个客户端，让它们在本机回环上真的握手、真的传报文。
##
## 单个进程的调用方式：
##   godot --headless --path . --script res://tools/tests/net_smoke.gd -- \
##       --role=host --name=主机 --expect=2
##   godot --headless --path . --script res://tools/tests/net_smoke.gd -- \
##       --role=client --name=小明 --ip=127.0.0.1 --port=8910
##
## 为什么本地回环也算有效验证：ENet 走的就是 UDP，握手、超时、RPC 路由、
## 掉线通知这些逻辑跟真机一模一样，只是少了 Wi-Fi 那一跳。
## 真机才会暴露的是路由器隔离、iOS 权限这类环境问题，那得插设备测。

const TIMEOUT_MS := 25000

var _room: Room
var _role := ""
var _name := "玩家"
var _ip := "127.0.0.1"
var _port := Protocol.GAME_PORT
var _expect := 1

var _inputs := 0
var _got_echo := false
var _done := false


func _initialize() -> void:
	if not _parse_args():
		quit(2)
		return

	# RPC 路径必须是 /root/Main/Room，所以这里手动搭出同一套结构。
	# 正式的 app 里这一段由 app/main.tscn 负责。
	var main := Node.new()
	main.name = "Main"
	root.add_child(main)

	_room = load("res://core/room/room.tscn").instantiate()
	main.add_child(_room)

	_room.joined.connect(_on_joined)
	_room.refused.connect(func(reason): _fail("被拒绝，原因 %d" % reason))
	_room.connection_lost.connect(func(reason): _fail("连接断开：%s" % reason))
	_room.game_input.connect(_on_game_input)
	_room.game_broadcast.connect(_on_broadcast)

	_run()


func _parse_args() -> bool:
	for arg in OS.get_cmdline_user_args():
		var parts := arg.split("=", true, 1)
		if parts.size() != 2:
			continue
		match parts[0]:
			"--role": _role = parts[1]
			"--name": _name = parts[1]
			"--ip": _ip = parts[1]
			"--port": _port = int(parts[1])
			"--expect": _expect = maxi(1, int(parts[1]))
	if _role != "host" and _role != "client":
		push_error("必须指定 --role=host 或 --role=client")
		return false
	return true


func _run() -> void:
	await process_frame

	if _role == "host":
		var port := _room.host_room(_name, 8)
		if port == 0:
			_fail("建房失败")
			return
		print("HOST_LISTENING port=%d" % port)
		await _host_flow()
	else:
		print("CLIENT_CONNECTING %s:%d" % [_ip, _port])
		_room.join_room(_ip, _port, _name)
		await _client_flow()


func _host_flow() -> void:
	# 1. 等人到齐
	if not await _wait_for(func(): return _room.get_player_count() >= _expect + 1):
		_fail("等玩家超时，当前 %d 人" % _room.get_player_count())
		return
	print("HOST_PLAYERS=%d 名单=%s" % [
		_room.get_player_count(), _names()])

	# 2. 开局
	_room.set_game("draw_guess", {"rounds": 1})
	if not _room.start_game():
		_fail("开局失败")
		return
	print("HOST_STARTED")

	# 3. 等每个客户端都把报文送上来，再回一个广播
	if not await _wait_for(func(): return _inputs >= _expect):
		_fail("等客户端报文超时，收到 %d 条" % _inputs)
		return
	print("HOST_GOT_INPUTS=%d" % _inputs)

	_room.rpc_game_broadcast.rpc(PackedByteArray([0xEE]))
	print("HOST_OK")
	# 别马上退：一退连接就断，客户端还没收到回包就会被判成掉线。
	# 真要做得严谨应该让客户端回一个 ACK，但冒烟测试不值得这么绕。
	await create_timer(2.0).timeout
	_finish(0)


func _client_flow() -> void:
	if not await _wait_for(func(): return _room.is_in_room() and _room.get_player_count() >= 2):
		_fail("进房超时")
		return
	print("CLIENT_PLAYERS=%d 名单=%s" % [
		_room.get_player_count(), _names()])

	_room.send_game_input(PackedByteArray([0x11, 0x22]))

	if not await _wait_for(func(): return _got_echo):
		_fail("没收到主机的广播回包")
		return
	print("CLIENT_OK")
	_finish(0)


func _on_joined() -> void:
	print("JOINED id=%d 是主机=%s" % [_room.get_local_id(), str(_room.is_host())])


func _on_game_input(sender: int, payload: PackedByteArray) -> void:
	_inputs += 1
	print("HOST_INPUT 来自 %d（%s）长度 %d" % [sender, _room.get_player_name(sender), payload.size()])


func _on_broadcast(payload: PackedByteArray) -> void:
	if payload.size() == 1 and payload[0] == 0xEE:
		_got_echo = true


func _names() -> String:
	var out := PackedStringArray()
	for entry in _room.get_state()["players"]:
		out.append("%s#%d" % [entry["name"], int(entry["peer_id"])])
	return "、".join(out)


func _wait_for(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await process_frame
	return false


func _fail(message: String) -> void:
	if _done:
		return
	push_error(message)
	print("FAILED: %s" % message)
	_finish(1)


func _finish(code: int) -> void:
	if _done:
		return
	_done = true
	_room.leave_room()
	quit(code)
