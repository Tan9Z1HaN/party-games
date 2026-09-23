class_name Transport
extends Node

## 连接抽象层（冻结契约，勿改）。
##
## 当前只有局域网实现：一名玩家当主机（ENet server），其他人直连他。
## 保留这层抽象是为了将来要加在线模式时，游戏逻辑层一行都不用改，
## 只需新增一个「连到云端服务器」的实现。
##
## 本文件只负责**连接的建立与断开**。消息收发走 Godot 的 RPC
## （multiplayer.multiplayer_peer），不从这里过。
##
## 必须挂进场景树（建议作为 Autoload），否则拿不到 multiplayer。

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


## 成为主机。端口被占用时按 Protocol.PORT_STEP 递增重试。
## 成功返回实际监听的端口号，失败返回 0。
func host(max_players: int) -> int:
	push_error("Transport.host() 未实现")
	return 0


## 作为客户端连接指定主机。
## 必须在 Protocol.CONNECT_TIMEOUT 秒内连上，否则发出 connection_failed。
func join(ip: String, port: int) -> void:
	push_error("Transport.join() 未实现")


## 断开连接。主机调用则解散房间。
func leave() -> void:
	push_error("Transport.leave() 未实现")


## 本机是否是主机
func is_host() -> bool:
	return false


## 本机是否已作为客户端连上主机
func is_connected_to_host() -> bool:
	return false


## 连接是否处于活动状态（主机或客户端皆可）
func is_active() -> bool:
	return false


## 本机在房间内的 peer_id。未连接时返回 0。
func get_local_peer_id() -> int:
	return 0


## 到某个玩家的往返延迟（毫秒）。未知返回 -1。
## 用于连接状态面板：让网络问题对玩家可见。
func get_ping_ms(peer_id: int) -> int:
	return -1


## 当前已连接的 peer_id 列表（不含自己）
func get_connected_peers() -> Array[int]:
	return []


## 本机的局域网 IP。找不到时返回空字符串。
## 主机用它生成二维码与「我的 IP」提示。
func get_local_ip() -> String:
	return ""
