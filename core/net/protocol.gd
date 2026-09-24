class_name Protocol
extends RefCounted

## 报文与通道定义（冻结契约，勿改已有内容）。
##
## 两条硬性设计约束：
##
## 1. 所有 RPC 都挂在固定节点路径上。Godot 的 RPC 依赖 NodePath 在两端一致，
##    不一致时会**静默失败**（不报错，只是收不到），是本项目最难排查的一类 bug。
##    两端加载的是同一套场景，所以路径天然一致——但别在运行期动态改变节点树形状。
##
## 2. 框架占用 0x01 ~ 0x1F，小游戏从 GAME_MSG 开始自定编号。
##    小游戏在游戏未开始时不得发送自己的报文。

## 协议版本。握手时双方必须一致，否则拒绝连接。
## 任何会影响两端兼容性的改动都要把它 +1。
##
## 3：握手报文加了游戏 id。房间在建房时就锁定玩什么，
##    选错游戏的人会被明确拒绝（老客户端发不出这个字段）。
## 2：笔迹格式改了（颜色由调色板索引改为 RGB，笔宽由三档改为 0~255 量化）。
## 老客户端连上来会被直接拒绝并提示版本不一致——这比「连上了但画出来的
## 线粗细颜色全不对」好查得多。
const VERSION := 3

## 房间控制器的 RPC 挂载点，两端必须完全一致。
const ROOM_RPC_PATH := ^"/root/Main/Room"

## 连接层（Transport）也带自己的 RPC（只用来测延迟），
## 它是 Room 的子节点，两端路径同样一致。
const TRANSPORT_RPC_PATH := ^"/root/Main/Room/Transport"

## 传输通道
const CH_RELIABLE := 0    ## 可靠有序：状态变更、指令
const CH_UNRELIABLE := 1  ## 不可靠：高频笔迹、心跳

## 连接超时（秒）。局域网下 5 秒足够，超时即判定失败。
## 注意 create_client() 返回 OK 不代表连上了，必须等信号并配超时。
const CONNECT_TIMEOUT := 5.0

## 端口。主机端口被占用时按 PORT_STEP 递增重试，最多 PORT_RETRIES 次。
## 实际使用的端口要写进邀请信息，客户端不需要知道默认值。
const GAME_PORT := 8910
const PORT_STEP := 2
const PORT_RETRIES := 4
const DISCOVERY_PORT := 8911

## 心跳间隔（秒）
const PING_INTERVAL := 1.0

## 一局最多几个人。房间满员判定和 UI 都用它。
const MAX_PLAYERS := 8

## 昵称长度上限（字符）
const MAX_NAME_CHARS := 8

## 框架消息类型
enum Msg {
	HELLO = 0x01,          ## 客户端 -> 主机：握手（协议版本、昵称）
	HELLO_ACK = 0x02,      ## 主机 -> 客户端：握手确认（分配的 peer_id、房间快照）
	REFUSE = 0x03,         ## 主机 -> 客户端：拒绝连接
	PLAYER_JOINED = 0x04,
	PLAYER_LEFT = 0x05,
	PLAYER_STATE = 0x06,   ## 准备状态、连接状态变化
	ROOM_CONFIG = 0x07,    ## 房主修改房间配置（选了哪款游戏、各参数）
	START_GAME = 0x08,     ## 房主开始游戏
	BACK_TO_LOBBY = 0x09,
	PING = 0x7E,
	PONG = 0x7F,
	GAME_MSG = 0x20,       ## 小游戏自定义报文起点
}

## 拒绝连接的原因
enum Refuse {
	VERSION_MISMATCH = 1,
	ROOM_FULL = 2,
	GAME_IN_PROGRESS = 3,
	GAME_MISMATCH = 4,   ## 房主开的不是你选的这款游戏
}

## 邀请串的 scheme。客户端扫码/粘贴后按此格式解析。
const URI_SCHEME := "godotlan"


## 生成 `godotlan://<ip>:<port>`，用于二维码与分享文本。
static func build_uri(ip: String, port: int) -> String:
	return "%s://%s:%d" % [URI_SCHEME, ip, port]


## 解析邀请串。失败返回空字典 {}。
static func parse_uri(text: String) -> Dictionary:
	var trimmed := text.strip_edges()
	var prefix := URI_SCHEME + "://"
	if not trimmed.begins_with(prefix):
		return {}
	var rest := trimmed.substr(prefix.length())
	var colon := rest.rfind(":")
	if colon <= 0:
		return {}
	var ip := rest.substr(0, colon)
	var port := rest.substr(colon + 1).to_int()
	if ip.is_empty() or port <= 0 or port > 65535:
		return {}
	return {"ip": ip, "port": port}
