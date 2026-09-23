class_name Transport
extends Node

## 连接抽象层（冻结契约，勿改签名）。
##
## 当前只有局域网实现：一名玩家当主机（ENet server），其他人直连他。
## 保留这层抽象是为了将来要加在线模式时，游戏逻辑层一行都不用改，
## 只需新增一个「连到云端服务器」的实现。
##
## 本文件只负责**连接的建立、断开与延迟测量**。
## 房间协议、握手、消息收发都在 Room 里（见 Protocol.ROOM_RPC_PATH）。
##
## 必须挂进场景树（作为 Room 的子节点），否则拿不到 multiplayer。
## RPC 依赖 NodePath 两端一致：本节点在两端都是 /root/Main/Room/Transport。

## 主机：端口已就绪，实际监听的端口见参数
signal host_started(port: int)

## 客户端：成功连上主机
signal connected()

## 连接失败，reason 取值见 FailReason
signal connection_failed(reason: int)

## 与主机的连接断开
signal server_disconnected()

## 有玩家加入 / 离开
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)

enum FailReason {
	TIMEOUT = 1,      ## 超时未连上（局域网下最常见：客户端隔离、iOS 权限被拒）
	REFUSED = 2,      ## 主机明确拒绝（版本不符 / 房间已满 / 游戏已开始）
	UNREACHABLE = 3,  ## 地址不可达（不在同一网段、IP 填错）
	UNKNOWN = 4,
}

const RPC_PING := &"_transport_ping"
const RPC_PONG := &"_transport_pong"

var _peer: ENetMultiplayerPeer = null
var _host_port := 0
var _connecting := false
var _connect_elapsed := 0.0
var _ping_elapsed := 0.0
var _pings := {}
var _last_host_error := OK


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	set_process(true)


func _process(delta: float) -> void:
	# 连接超时。create_client() 返回 OK 只代表「开始尝试」，不代表连上了，
	# 不设超时的话弱网下会一直干等。
	if _connecting:
		_connect_elapsed += delta
		if _connect_elapsed >= Protocol.CONNECT_TIMEOUT:
			_fail(FailReason.TIMEOUT)
			return

	if not is_active():
		return

	_ping_elapsed += delta
	if _ping_elapsed >= Protocol.PING_INTERVAL:
		_ping_elapsed = 0.0
		_ping_all()


## 成为主机。端口被占用时按 Protocol.PORT_STEP 递增重试。
## 成功返回实际监听的端口号，失败返回 0。
func host(max_players: int) -> int:
	leave()
	_last_host_error = OK

	# 先试几个固定端口（好让人手输地址），再退到随机高位端口兜底。
	# 固定端口可能撞上别的程序、被 Hyper-V/WSL 保留，或者被安全软件拦。
	var ports: Array[int] = []
	for i in Protocol.PORT_RETRIES:
		ports.append(Protocol.GAME_PORT + i * Protocol.PORT_STEP)
	for i in 8:
		ports.append(randi_range(27000, 49000))

	for port in ports:
		var peer := ENetMultiplayerPeer.new()
		# ENet 的 max_clients 不含主机自己
		var err := peer.create_server(port, maxi(1, max_players - 1))
		if err == OK:
			_peer = peer
			multiplayer.multiplayer_peer = peer
			_host_port = port
			host_started.emit(port)
			return port
		_last_host_error = err

	# 20 = ERR_CANT_CREATE（创建不了 socket，安卓上多半是没给 INTERNET 权限）
	# 32 = ERR_ALREADY_IN_USE
	push_error("起主机失败，最后一次错误码 %d（20=创建不了，32=已被占用）" % _last_host_error)
	return 0


## 上次建房失败的错误码。UI 用它给出真实原因，
## 不要再一律说成「端口被占用」——那会把权限问题伪装成端口冲突。
func get_last_host_error() -> int:
	return _last_host_error


## 作为客户端连接指定主机。
## 必须在 Protocol.CONNECT_TIMEOUT 秒内连上，否则发出 connection_failed。
func join(ip: String, port: int) -> void:
	leave()

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		# 地址格式就不对，连尝试都不用
		_fail(FailReason.UNREACHABLE)
		return

	_peer = peer
	multiplayer.multiplayer_peer = peer
	_connecting = true
	_connect_elapsed = 0.0


## 断开连接。主机调用则解散房间。
func leave() -> void:
	if _peer != null:
		_peer.close()
	_peer = null
	_connecting = false
	_connect_elapsed = 0.0
	_ping_elapsed = 0.0
	_pings.clear()
	if multiplayer != null and multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null


## 本机是否是主机
func is_host() -> bool:
	return _peer != null and multiplayer.is_server()


## 本机是否已作为客户端连上主机
func is_connected_to_host() -> bool:
	if _peer == null or multiplayer.is_server():
		return false
	return _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


## 连接是否处于活动状态（主机或客户端皆可）
func is_active() -> bool:
	if _peer == null:
		return false
	return multiplayer.is_server() or is_connected_to_host()


## 本机在房间内的 peer_id。未连接时返回 0。
func get_local_peer_id() -> int:
	if not is_active():
		return 0
	return multiplayer.get_unique_id()


## 主机实际监听的端口。没当主机时返回 0。
func get_host_port() -> int:
	return _host_port


## 到某个玩家的往返延迟（毫秒）。还没测到返回 -1。
## 用于连接状态面板：让网络问题对玩家可见。
func get_ping_ms(peer_id: int) -> int:
	return int(_pings.get(peer_id, -1))


## 当前已连接的 peer_id 列表（不含自己）
func get_connected_peers() -> Array[int]:
	var out: Array[int] = []
	if _peer == null:
		return out
	for id in multiplayer.get_peers():
		out.append(int(id))
	return out


## 本机的局域网 IP。找不到时返回空字符串。
## 主机用它生成邀请信息；客户端用它做「你和主机不在同一网段」的提示。
func get_local_ip() -> String:
	var candidates: Array[String] = []
	for address in IP.get_local_addresses():
		if address.contains(":"):
			continue                       # 跳过 IPv6
		if address.begins_with("127.") or address.begins_with("169.254."):
			continue                       # 回环与链路本地地址没用
		candidates.append(address)

	if candidates.is_empty():
		return ""

	# 家用/办公路由器最常见的是 192.168.x.x，优先它。
	# 注意 MuMu 之类的模拟器会额外带来 172.x 的虚拟网卡，别优先选它。
	for prefix in ["192.168.", "10.", "172."]:
		for address in candidates:
			if address.begins_with(prefix):
				return address
	return candidates[0]


# ---------------------------------------------------------------- RPC

@rpc("any_peer", "call_remote", "unreliable")
func _transport_ping(stamp: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender > 0:
		_transport_pong.rpc_id(sender, stamp)


@rpc("any_peer", "call_remote", "unreliable")
func _transport_pong(stamp: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender > 0:
		_pings[sender] = Time.get_ticks_msec() - stamp


func _ping_all() -> void:
	var stamp := Time.get_ticks_msec()
	for peer_id in get_connected_peers():
		_transport_ping.rpc_id(peer_id, stamp)


# ---------------------------------------------------------------- 内部

func _fail(reason: FailReason) -> void:
	leave()
	connection_failed.emit(reason)


func _on_connected_to_server() -> void:
	_connecting = false
	connected.emit()


func _on_connection_failed() -> void:
	_fail(FailReason.REFUSED)


func _on_server_disconnected() -> void:
	leave()
	server_disconnected.emit()


func _on_peer_connected(peer_id: int) -> void:
	peer_joined.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	_pings.erase(peer_id)
	peer_left.emit(peer_id)
