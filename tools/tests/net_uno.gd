extends SceneTree

## UNO 联机的多进程测试。不要单独跑它——
## 配套脚本 tools/tests/run_net_uno.ps1 会同时起一个主机和若干客户端。
##
## 单个进程的调用方式：
##   godot --headless --path . --script res://tools/tests/net_uno.gd -- \
##       --role=host --name=主机 --expect=2
##   godot --headless --path . --script res://tools/tests/net_uno.gd -- \
##       --role=client --name=小明 --ip=127.0.0.1
##
## 这个脚本**真的打完一整局**：每个进程只在自己的回合出牌，报文走 ENet，
## 房主跑规则并广播状态、单发手牌。最后各进程各自报出赢家，
## 由外层脚本比对三边是不是同一个赢家。
##
## 这一步是防「房主那边是对的、客户端显示的是错的」的关键：
## 这类问题在单个进程里怎么测都是对的。

const TIMEOUT_MS := 45000
const ACTION_INTERVAL := 0.25   ## 每隔多久尝试动作一次，别把网络刷爆
const LINGER := 2.5             ## 打完之后多留一会儿再退出，别把别人挤下线

var _room: Room
var _game: UnoGame
var _role := "host"
var _name := "player"
var _ip := "127.0.0.1"
var _port := Protocol.GAME_PORT
var _expect := 2

var _elapsed := 0.0
var _act_elapsed := 0.0
var _finished := false
var _sent := 0
var _rejected := 0
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
	_room.game_broadcast.connect(_on_broadcast)
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
		_room.set_game("uno", {})
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

	# 开局之后各族自己往下打，直到分出胜负
	if not await _wait_for(func(): return _game != null):
		_fail("等开局超时")
		return
	if _role == "host":
		print("HOST_READY players=%d" % _room.get_player_count())
	_started_at = Time.get_ticks_msec()
	await _play_loop()


## 主循环。SceneTree 的 _process 是另一套签名，所以这里自己转圈。
func _play_loop() -> void:
	var last := Time.get_ticks_msec()
	while not _finished:
		if Time.get_ticks_msec() - _started_at > TIMEOUT_MS:
			_fail("打完超时。最后看到的公开状态：%s" % str(_public()))
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

	if int(s.get("color_chooser", 0)) == _game.local_peer_id():
		# 挑手牌里最多的那个颜色，跟真人思路接近
		_game.submit(UnoMessages.encode_choose_color(_best_color(s)))
		return
	if int(s.get("current", 0)) != _game.local_peer_id():
		return

	var card := -1
	for c in Array(s.get("my_hand", [])):
		if _game.can_play(int(c)):
			card = int(c)
			break
	if card >= 0:
		_game.submit(UnoMessages.encode_play(card, -1))
	else:
		_game.submit(UnoMessages.encode_draw())
	_sent += 1


## 房间广播开局 -> 两端都建同一个游戏对象。跟 app.gd 里的流程一致。
func _on_game_started(_game_id: String, config: Dictionary) -> void:
	if _game != null:
		return
	_game = UnoGame.new()
	root.add_child(_game)
	_game.setup(_room.get_state()["players"], config)
	_game.event_log.connect(func(text): print("%s_LOG %s" % [_tag(), text]))
	# 客户端要靠这个把操作转发给房主。忘了它，点什么都纹丝不动。
	_game.bind_room(_room)
	_room.attach_game(_game)
	if _room.is_host():
		_game.start_round()


func _on_broadcast(payload: PackedByteArray) -> void:
	if _game == null:
		return
	_game.on_remote_message(payload)
	# 被拒说明我们是拿旧状态做的决定，下一轮重试就行
	if payload.size() > 0 and payload[0] == UnoMessages.Action.REJECT:
		_rejected += 1


func _on_snapshot(snapshot: Dictionary) -> void:
	if _game != null:
		_game.apply_snapshot(snapshot)


var _ok := false


func _best_color(s: Dictionary) -> int:
	var tally := {0: 0, 1: 0, 2: 0, 3: 0}
	for c in Array(s.get("my_hand", [])):
		var color := UnoDeck.color_of(int(c))
		if tally.has(color):
			tally[color] += 1
	var best := 0
	for color in tally:
		if tally[color] > tally[best]:
			best = color
	return best


func _public() -> Dictionary:
	var s := _game.state() if _game != null else {}
	return {
		"top": s.get("top_card"),
		"current": s.get("current"),
		"pending": s.get("pending_draw"),
		"chooser": s.get("color_chooser"),
		"finished": s.get("finished"),
	}


func _report(s: Dictionary) -> void:
	if _finished:
		return
	_finished = true
	_ok = true
	# 手牌这里只报自己那份的数量。它是主机单发过来的，
	# 报得出来就说明隐藏信息这条路真的通了。
	print("%s_HAND=%d SENT=%d REJECTED=%d" % [
		_tag(), Array(s.get("my_hand", [])).size(), _sent, _rejected])
	print("%s_WINNER=%d" % [_tag(), int(s.get("winner", 0))])
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
	# 打完之后谁先退出，其他人都会看到"连接断开"——那不是错误，别报出来。
	if _ok:
		return
	_finished = true
	print("FAILED %s" % message)
	quit(1)
