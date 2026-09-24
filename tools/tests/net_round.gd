extends SceneTree

## 联机打完整局的集成测试。
##
## 由 tools/tests/run_net_round.ps1 驱动：起 1 个主机 + N 个客户端，
## 真的把一局你画我猜从头打完，**然后由脚本比对三个进程各自记录到了什么**。
##
## 为什么要跨进程比对，而不是各测各的：
## 这段时间报上来的 bug 几乎都是「两边状态不一致」——
## 非画手能改画布、猜词被算成画手、客户端结算行是空的、
## 选词面板对所有人可见。这些在单进程里全是对的，
## 只有把两边的记录摆在一起看才露馅。
##
## 单个进程的调用方式（不要单独跑，看脚本）：
##   godot --headless --path . --script res://tools/tests/net_round.gd -- \
##       --role=host --name=host --expect=2

## 测试词库只有这几个词，所以猜词者可以「全都试一遍」。
## 这不是作弊——它仍然只能靠主机判定才知道哪个对，
## 走的正是真实玩家的那条路。
const TEST_WORDS := ["苹果", "香蕉", "西瓜", "葡萄", "樱桃", "柠檬"]
const TEST_BANK := "res://tools/tests/words_net_round.txt"

## 整局最长等多久（毫秒）
const MAX_MS := 100000

var _room: Room
var _game: DrawGuessGame

var _role := ""
var _name := "player"
var _ip := "127.0.0.1"
var _port := Protocol.GAME_PORT
var _expect := 2

var _checks := 0
var _rounds := 0
var _drawing_round := -1
var _done := false


func _initialize() -> void:
	if not _parse_args():
		quit(2)
		return

	# RPC 路径必须是 /root/Main/Room，手动搭出同一套结构
	var main := Node.new()
	main.name = "Main"
	root.add_child(main)
	_room = load("res://core/room/room.tscn").instantiate()
	main.add_child(_room)

	_room.joined.connect(func(): print("ROLE=%s id=%d host=%s" % [
		_role, _room.get_local_id(), str(_room.is_host())]))
	_room.refused.connect(func(reason): _fail("被拒绝，原因 %d" % reason))
	_room.connection_lost.connect(func(reason): _fail("连接断开：%s" % reason))
	_room.state_changed.connect(_on_state_changed)
	_room.game_started.connect(_on_game_started)
	_room.game_broadcast.connect(func(payload):
		if _game != null:
			_game.on_remote_message(payload))
	_room.game_snapshot.connect(func(snapshot):
		if _game != null:
			_game.apply_snapshot(snapshot))

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
		if not await _wait_for(func(): return _room.get_player_count() >= _expect + 1):
			_fail("等人超时，只到了 %d 人" % _room.get_player_count())
			return
		print("PLAYERS=%d" % _room.get_player_count())
		# 房主开局：先把配置定好再 start，客户端靠这条报文拿到同一份配置
		_room.set_game("draw_guess", _config())
		if not _room.start_game():
			_fail("开局失败")
			return
	else:
		_room.join_room(_ip, _port, _name)
		if not await _wait_for(func(): return _room.is_in_room() or _done):
			_fail("进房超时")
			return

	# 等整局跑完（或者超时）
	var deadline := Time.get_ticks_msec() + MAX_MS
	while Time.get_ticks_msec() < deadline:
		if _done:
			return
		if _game != null and _game.is_finished():
			print("FINISHED rounds=%d" % _rounds)
			_finish(0)
			return
		await process_frame

	_fail("整局没跑完（超时）")


func _config() -> Dictionary:
	return {
		"rounds": 3,
		"round_seconds": 3,      # 短一点，测试别跑太久
		"difficulty": 1,
		"hints": true,
		"word_bank_path": TEST_BANK,
	}


func _on_game_started(_game_id: String, config: Dictionary) -> void:
	if _game != null:
		return
	_game = DrawGuessGame.new()
	# 必须挂进场景树：不在树里时 _is_networked() 会返回 false，
	# 客户端就会误以为自己是权威端，整套判定都错。
	root.add_child(_game)
	_game.setup(_room.get_state()["players"], config)
	_room.attach_game(_game)
	_game.round_settled.connect(_on_round_settled)
	_game.candidates_offered.connect(_on_candidates)
	_game.phase_changed.connect(_on_phase_changed)

	if _room.is_host():
		_game.start_round()


## 轮到谁选词谁就选第一个。主机和客户端走的是同一条逻辑，
## 区别只在 _room.send_game_input() 内部（主机本地直达，客户端发 RPC）。
func _on_candidates(candidates: Array) -> void:
	if candidates.is_empty():
		return
	var i_am_drawer := _game.is_drawer(_game.get_local_id())
	# 主机上这个信号每轮都会响（游戏逻辑在它这儿跑），
	# 但客户端只该在「自己当画手」时收到候选词。
	# 客户端出现 is_drawer=false，就是泄题。
	print("CANDIDATES r=%d is_drawer=%s count=%d" % [
		_game.get_round_index(), str(i_am_drawer), candidates.size()])
	if i_am_drawer:
		_room.send_game_input(DrawGuessMessages.encode_pick_word(0))


func _on_phase_changed(phase: int, _left: float) -> void:
	# tick() 每帧都会发 phase_changed，所以只在阶段真正切换时动作
	if phase != DrawGuessGame.Phase.DRAWING:
		return
	var round_index := _game.get_round_index()
	if round_index == _drawing_round:
		return
	_drawing_round = round_index

	var me := _game.get_local_id()
	var i_am_drawer := _game.is_drawer(me)
	# 防泄露：非画手在作画阶段拿到的答案必须是空的
	print("LEAKCHECK r=%d is_drawer=%s seen_len=%d" % [
		round_index, str(i_am_drawer), _game.get_word_for(me).length()])

	if not i_am_drawer:
		# 等一会儿再猜。真人不会在画手刚下笔时就报答案，
		# 而且这里必须留出观察窗口——否则作画阶段短到客户端
		# 根本收不到快照，下面的防泄露检查就成了空转。
		await create_timer(1.5).timeout
		if _done or _game == null or _game.get_phase() != DrawGuessGame.Phase.DRAWING:
			return
		# 猜词者：把测试词库里的词全试一遍。
		# 它并不知道哪个对——必须靠主机判定后广播回来才知道。
		for word in TEST_WORDS:
			_room.send_game_input(DrawGuessMessages.encode_guess(word))


## 每个进程各记一份，交给脚本比对。
func _on_round_settled(word: String, rows: Array) -> void:
	_rounds += 1
	var scores := _game.get_scores()
	var keys := scores.keys()
	keys.sort()
	var parts := PackedStringArray()
	for key in keys:
		parts.append("%d:%d" % [int(key), int(scores[key])])
	print("ROUND r=%d drawer=%d word=%s rows=%d scores=%s" % [
		_game.get_round_index(), _game.get_drawer_peer_id(), word,
		rows.size(), ",".join(parts)])


func _on_state_changed(_state: Dictionary) -> void:
	pass


func _wait_for(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		if _done:
			return false
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
