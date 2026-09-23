class_name Room
extends Node

## 房间控制器。挂在固定的 /root/Main/Room 上，所有 RPC 都从这里进出。
##
## 主机权威模型：房主既是玩家也是服务器，房间状态只由房主维护，
## 其他人收到的是房主广播的快照。
##
## 通信分三类：
##   1. 握手      客户端 HELLO -> 房主 HELLO_ACK / REFUSE
##   2. 房间状态  房主单向广播快照（玩家列表、选了哪款游戏、开局了没）
##   3. 游戏报文  客户端上行 -> 房主转交游戏逻辑；房主下行 -> 广播或单发
##
## 注意 RPC 依赖 NodePath 两端一致。两端加载的是同一套场景，
## 运行期也不要增删 Room 下面的节点，否则会静默收不到消息。

enum Mode { OFFLINE, HOST, CLIENT }

## 房间状态有变化（玩家进出、改名、换游戏、开局）
signal state_changed(state: Dictionary)

## 本机成功进了房间（自己建的，或连上别人的）
signal joined()

## 被拒绝 / 连不上 / 掉线
signal refused(reason: int)
signal connection_lost(reason: String)

## 房主宣布开局
signal game_started(game_id: String, config: Dictionary)

## 游戏报文（已经过来源校验）
signal game_input(sender: int, payload: PackedByteArray)
signal game_broadcast(payload: PackedByteArray)
signal game_snapshot(snapshot: Dictionary)

const RPC_HELLO := &"rpc_hello"
const RPC_HELLO_ACK := &"rpc_hello_ack"
const RPC_REFUSE := &"rpc_refuse"
const RPC_STATE := &"rpc_state"
const RPC_START := &"rpc_start"
const RPC_GAME_INPUT := &"rpc_game_input"
const RPC_GAME_BROADCAST := &"rpc_game_broadcast"
const RPC_GAME_SNAPSHOT := &"rpc_game_snapshot"

## 房主多久同步一次游戏状态（秒）。倒计时靠它校准。
const SNAPSHOT_INTERVAL := 0.25

var transport: Transport

var _mode := Mode.OFFLINE
var _nickname := ""
var _max_players := Protocol.MAX_PLAYERS
var _players := {}                 ## peer_id -> {peer_id, name}
var _host_id := 0
var _game_id := ""
var _config := {}
var _started := false
var _snapshot_elapsed := 0.0
var _game: MiniGame = null


func _ready() -> void:
	transport = Transport.new()
	transport.name = "Transport"
	add_child(transport)

	transport.host_started.connect(_on_host_started)
	transport.connected.connect(_on_connected)
	transport.connection_failed.connect(_on_connection_failed)
	transport.server_disconnected.connect(_on_server_disconnected)
	transport.peer_left.connect(_on_peer_left)


func _process(delta: float) -> void:
	# 游戏计时由房间统一驱动：主机推进真实状态，客户端只做本地插值
	# （否则倒计时会一跳一跳的）。
	if _game != null:
		_game.tick(delta)

	# 房主定期把游戏状态推给客户端，用于校准倒计时等本地表现
	if _mode != Mode.HOST or _game == null or not _started:
		return
	_snapshot_elapsed += delta
	if _snapshot_elapsed < SNAPSHOT_INTERVAL:
		return
	_snapshot_elapsed = 0.0
	rpc_game_snapshot.rpc(_game.snapshot())


# ---------------------------------------------------------------- 对外接口

## 建房。返回实际监听的端口，0 表示失败。
func host_room(nickname: String, max_players := Protocol.MAX_PLAYERS) -> int:
	leave_room()
	_nickname = _clean_name(nickname)
	_max_players = clampi(max_players, 2, Protocol.MAX_PLAYERS)

	var port := transport.host(_max_players)
	if port == 0:
		return 0
	return port


## 加入别人的房间。结果通过 joined / refused 信号通知。
func join_room(ip: String, port: int, nickname: String) -> void:
	leave_room()
	_nickname = _clean_name(nickname)
	_mode = Mode.CLIENT
	transport.join(ip, port)


func leave_room() -> void:
	transport.leave()
	_mode = Mode.OFFLINE
	_players.clear()
	_host_id = 0
	_game_id = ""
	_config = {}
	_started = false
	_game = null


func get_mode() -> Mode:
	return _mode


func is_host() -> bool:
	return _mode == Mode.HOST


func is_in_room() -> bool:
	return _mode != Mode.OFFLINE


func get_local_id() -> int:
	return transport.get_local_peer_id()


func get_local_name() -> String:
	return _nickname


## 房间快照。UI 只读它，不要自己维护一份玩家列表。
func get_state() -> Dictionary:
	var list: Array = []
	for peer_id in _players:
		list.append(_players[peer_id].duplicate())
	list.sort_custom(func(a, b): return int(a["peer_id"]) < int(b["peer_id"]))
	return {
		"host_id": _host_id,
		"game_id": _game_id,
		"config": _config.duplicate(),
		"started": _started,
		"players": list,
		"max_players": _max_players,
	}


func get_player_count() -> int:
	return _players.size()


func get_player_name(peer_id: int) -> String:
	if _players.has(peer_id):
		return String(_players[peer_id]["name"])
	return ""


## 房主：选定游戏与配置，立刻同步给所有人
func set_game(game_id: String, config: Dictionary) -> void:
	if _mode != Mode.HOST:
		return
	_game_id = game_id
	_config = config.duplicate()
	_broadcast_state()


## 房主：开局
func start_game() -> bool:
	if _mode != Mode.HOST:
		return false
	if _game_id.is_empty():
		push_error("还没选游戏")
		return false
	if _players.size() < 2:
		push_error("至少要两个人")
		return false
	_started = true
	rpc_start.rpc(_game_id, _config)
	_apply_start(_game_id, _config)
	_broadcast_state()
	return true


## 把游戏对象挂给房间，之后报文会自动在它和网络之间流转。
## 两端都要挂：房主用它做判定，客户端用它做表现。
func attach_game(game: MiniGame) -> void:
	_game = game
	if _mode == Mode.HOST:
		game.broadcast_requested.connect(_on_game_wants_broadcast)
		game.to_player_requested.connect(_on_game_wants_unicast)


func get_game() -> MiniGame:
	return _game


## 把本机玩家的操作发给房主。
## 房主自己调用时直接进本地游戏，不绕一圈网络。
func send_game_input(payload: PackedByteArray) -> void:
	if _mode == Mode.HOST:
		if _game != null:
			_game.on_player_input(get_local_id(), payload)
	elif _mode == Mode.CLIENT:
		rpc_game_input.rpc_id(1, payload)


# ---------------------------------------------------------------- 握手

@rpc("any_peer", "call_remote", "reliable")
func rpc_hello(version: int, nickname: String) -> void:
	if _mode != Mode.HOST:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 0:
		return

	if version != Protocol.VERSION:
		_reject(sender, Protocol.Refuse.VERSION_MISMATCH)
		return
	if _players.size() >= _max_players:
		_reject(sender, Protocol.Refuse.ROOM_FULL)
		return
	if _started:
		_reject(sender, Protocol.Refuse.GAME_IN_PROGRESS)
		return

	_players[sender] = {"peer_id": sender, "name": _clean_name(nickname)}
	rpc_hello_ack.rpc_id(sender, get_state())
	_broadcast_state()


@rpc("authority", "call_remote", "reliable")
func rpc_hello_ack(state: Dictionary) -> void:
	_apply_state(state)
	joined.emit()


@rpc("authority", "call_remote", "reliable")
func rpc_refuse(reason: int) -> void:
	leave_room()
	refused.emit(reason)


@rpc("authority", "call_remote", "reliable")
func rpc_state(state: Dictionary) -> void:
	_apply_state(state)


@rpc("authority", "call_remote", "reliable")
func rpc_start(game_id: String, config: Dictionary) -> void:
	_game_id = game_id
	_config = config.duplicate()
	_started = true
	_apply_start(game_id, config)


# ---------------------------------------------------------------- 游戏报文

@rpc("any_peer", "call_remote", "reliable")
func rpc_game_input(payload: PackedByteArray) -> void:
	if _mode != Mode.HOST:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 0 or not _players.has(sender):
		# 没完成握手就发游戏报文，一律丢掉
		return
	# 转交给游戏逻辑。**身份必须用 sender**，不能用本机 id——
	# 否则客户端的一切操作都会被当成房主自己做的。
	if _game != null:
		_game.on_player_input(sender, payload)
	game_input.emit(sender, payload)


@rpc("authority", "call_remote", "reliable")
func rpc_game_broadcast(payload: PackedByteArray) -> void:
	game_broadcast.emit(payload)


@rpc("authority", "call_remote", "reliable")
func rpc_game_snapshot(snapshot: Dictionary) -> void:
	game_snapshot.emit(snapshot)


## 房主把游戏报文广播给所有人（不含自己，自己本地已经处理过了）
func _on_game_wants_broadcast(payload: PackedByteArray) -> void:
	if _mode == Mode.HOST:
		rpc_game_broadcast.rpc(payload)


## 房主把游戏报文单发给某个人。隐藏信息（比如 UNO 手牌）走这条路。
func _on_game_wants_unicast(peer_id: int, payload: PackedByteArray) -> void:
	if _mode != Mode.HOST:
		return
	if peer_id == get_local_id():
		game_broadcast.emit(payload)
		return
	rpc_game_broadcast.rpc_id(peer_id, payload)


# ---------------------------------------------------------------- 内部

func _on_host_started(_port: int) -> void:
	_mode = Mode.HOST
	_host_id = transport.get_local_peer_id()
	_players = {_host_id: {"peer_id": _host_id, "name": _nickname}}
	joined.emit()
	_broadcast_state()


func _on_connected() -> void:
	# 连上了，但还没进房间——先握手
	rpc_hello.rpc_id(1, Protocol.VERSION, _nickname)


func _on_connection_failed(reason: int) -> void:
	_mode = Mode.OFFLINE
	refused.emit(reason)


func _on_server_disconnected() -> void:
	_mode = Mode.OFFLINE
	connection_lost.emit("host_left")


func _on_peer_left(peer_id: int) -> void:
	if _mode != Mode.HOST:
		return
	if not _players.has(peer_id):
		return
	_players.erase(peer_id)
	_broadcast_state()


func _reject(peer_id: int, reason: int) -> void:
	rpc_refuse.rpc_id(peer_id, reason)
	# 给客户端一点时间收到拒绝原因再断开
	await get_tree().create_timer(0.2).timeout
	var peer := multiplayer.multiplayer_peer
	if peer is ENetMultiplayerPeer:
		(peer as ENetMultiplayerPeer).disconnect_peer(peer_id, true)


func _broadcast_state() -> void:
	var state := get_state()
	if _mode == Mode.HOST:
		rpc_state.rpc(state)
	state_changed.emit(state)


func _apply_state(state: Dictionary) -> void:
	_host_id = int(state.get("host_id", 0))
	_game_id = String(state.get("game_id", ""))
	_config = state.get("config", {})
	_started = bool(state.get("started", false))
	_max_players = int(state.get("max_players", Protocol.MAX_PLAYERS))
	_players.clear()
	for entry in state.get("players", []):
		_players[int(entry["peer_id"])] = entry.duplicate()
	state_changed.emit(get_state())


func _apply_start(game_id: String, config: Dictionary) -> void:
	_started = true
	_snapshot_elapsed = 0.0
	game_started.emit(game_id, config)


func _clean_name(nickname: String) -> String:
	var name := nickname.strip_edges()
	if name.is_empty():
		name = "玩家"
	if name.length() > Protocol.MAX_NAME_CHARS:
		name = name.substr(0, Protocol.MAX_NAME_CHARS)
	return name
