extends SceneTree

## 环游中国联机的多进程测试。不要单独跑——
## 配套脚本 tools/tests/run_net_tour.ps1 会同时起一个主机和若干客户端。
##
##   godot --headless --path . --script res://tools/tests/net_tour.gd -- \
##       --role=host --name=主机 --expect=2
##   godot --headless --path . --script res://tools/tests/net_tour.gd -- \
##       --role=client --name=小明 --ip=127.0.0.1
##
## 每个进程只在自己的回合出招，报文走 ENet，房主跑规则并广播完整状态。
## 最后各进程各自报出赢家，由外层脚本比对几边是不是同一个。

const TIMEOUT_MS := 60000
const ACTION_INTERVAL := 0.25   ## 每隔多久尝试动作一次，别把网络刷爆
const LINGER := 2.5             ## 打完之后多留一会儿再退出，别把别人挤下线

var _room: Room
var _game: TourGame
var _role := "host"
var _name := "player"
var _ip := "127.0.0.1"
var _port := Protocol.GAME_PORT
var _expect := 2

var _act_elapsed := 0.0
var _finished := false
var _ok := false
var _sent := 0
var _started_at := 0


func _initialize() -> void:
	if not _parse_args():
		quit(2)
		return
	var main := Node.new()
	main.name = "Main"
	root.add_child(main)
	_room = load("res://core/room/room.tscn").instantiate()
	main.add_child(_room)
	_room.joined.connect(func(): print("%s_JOINED id=%d" % [_tag(), _room.get_local_id()]))
	_room.refused.connect(func(r): _fail("被拒绝 %d" % r))
	_room.connection_lost.connect(func(r): _fail("连接断开 %s" % r))
	_room.game_started.connect(_on_game_started)
	_room.game_snapshot.connect(_on_snapshot)
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
		print("HOST_PORT=%d" % port)
		if not await _wait_for(func(): return _room.get_player_count() >= _expect + 1):
			_fail("等人超时，来了 %d 个" % _room.get_player_count())
			return
		_room.set_game("tour", {})
		if not _room.start_game():
			_fail("开局失败")
			return
		print("HOST_STARTED players=%d" % _room.get_player_count())
	else:
		_room.join_room(_ip, _port, _name)
		if not await _wait_for(func(): return _room.is_in_room() and _room.get_player_count() >= 2):
			_fail("进房超时")
			return
		print("CLIENT_IN players=%d" % _room.get_player_count())

	if not await _wait_for(func(): return _game != null):
		_fail("等开局超时")
		return
	if _role == "host":
		print("HOST_READY players=%d" % _room.get_player_count())
	_started_at = Time.get_ticks_msec()
	await _play_loop()


func _play_loop() -> void:
	var last := Time.get_ticks_msec()
	while not _finished:
		if Time.get_ticks_msec() - _started_at > TIMEOUT_MS:
			_fail("打完超时。最后看到的：%s" % str(_public()))
			return
		await process_frame
		var now := Time.get_ticks_msec()
		_act(float(now - last) / 1000.0)
		last = now
	if not _ok:
		return
	await create_timer(LINGER).timeout
	quit(0)


func _act(delta: float) -> void:
	if _game == null or _finished:
		return
	var s := _game.state()
	if s.is_empty():
		return
	if bool(s.get("finished", false)):
		_report(s)
		_ok = true
		return

	_act_elapsed += delta
	if _act_elapsed < ACTION_INTERVAL:
		return
	_act_elapsed = 0.0
	if int(s.get("current", 0)) != _game.local_peer_id():
		return

	# 轮到我了：按当前要决定的事情发一条指令。客户端用的是最多 0.25 秒前的
	# 状态，可能已经被别人超车——房主会拒掉，下一轮重试。
	match int(s.get("decision", 0)):
		TourRules.Decision.BUY:
			_game.submit(TourMessages.encode_buy())
		TourRules.Decision.UPGRADE:
			_game.submit(TourMessages.encode_upgrade())
		TourRules.Decision.TAX:
			var tax: Dictionary = s.get("tax", {})
			if String(tax.get("cheaper", "flat")) == "percent":
				_game.submit(TourMessages.encode_tax_percent())
			else:
				_game.submit(TourMessages.encode_tax_flat())
		_:
			_game.submit(TourMessages.encode_roll())
	_sent += 1


## 房间广播开局 -> 两端都建同一个游戏对象。跟 app.gd 里的流程一致。
func _on_game_started(_game_id: String, config: Dictionary) -> void:
	if _game != null:
		return
	_game = TourGame.new()
	root.add_child(_game)
	_game.setup(_room.get_state()["players"], config)
	_game.bind_room(_room)
	_room.attach_game(_game)
	if _room.is_host():
		_game.start_round()


func _on_snapshot(snapshot: Dictionary) -> void:
	if _game != null:
		_game.apply_snapshot(snapshot)


func _public() -> Dictionary:
	var s := _game.state() if _game != null else {}
	return {
		"current": s.get("current"),
		"phase": s.get("phase"),
		"alive": s.get("alive"),
		"finished": s.get("finished"),
		"round": s.get("round"),
	}


func _report(s: Dictionary) -> void:
	if _finished:
		return
	_finished = true
	_ok = true
	print("%s_SENT=%d ALIVE=%d ROUND=%d" % [
		_tag(), _sent, int(s.get("alive", 0)), int(s.get("round", 1))])
	var rows := _game.get_results()
	print("%s_WINNER=%d" % [_tag(), int(rows[0]["peer_id"]) if not rows.is_empty() else 0])
	print("%s_OK" % _tag())


func _tag() -> String:
	return "HOST" if _role == "host" else "CLIENT"


func _wait_for(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await process_frame
	return false


func _fail(message: String) -> void:
	# 打完之后谁先退出，其他人都会看到「连接断开」——那不是错误
	if _ok:
		return
	_finished = true
	print("FAILED %s" % message)
	quit(1)
