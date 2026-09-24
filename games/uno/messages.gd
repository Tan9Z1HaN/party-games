class_name UnoMessages
extends RefCounted

## UNO 的小游戏报文。
##
## 房间层只负责把 payload 原样转给 MiniGame.on_player_input()，
## 具体含义由这里定义。所有报文第一个字节都是 Action。
##
## 两类通道别搞混：
##   - **广播**（PLAYED / DREW / LOG）谁都能看，用来放动画和刷新日志；
##   - **单发**（SET_HAND / REJECT）只给某一个玩家。
## 手牌**绝不能进广播**。熟人局作弊风险低，但那是信息正确性问题：
## 广播出去之后，一个抓包工具就能看穿全场，而单发的成本几乎为零。

enum Action {
	# ---- 客户端 -> 房主：意图。房主负责校验，非法一律丢弃 ----
	PLAY = 1,           ## u8 card, u8 chosen_color（255 表示没指定）
	DRAW = 2,           ## 无附加数据
	PASS = 3,           ## 无附加数据
	SAY_UNO = 4,        ## 无附加数据
	CHOOSE_COLOR = 5,   ## u8 color

	# ---- 房主 -> 所有人 ----
	PLAYED = 7,         ## u16 peer_id, u8 card
	DREW = 8,           ## u16 peer_id, u8 count
	LOG = 9,            ## u16 字节数 + utf8（已经本地化好的状态说明）

	# ---- 房主 -> 某一个人 ----
	SET_HAND = 12,      ## u8 count, count × u8 card
	REJECT = 13,        ## u16 字节数 + utf8（操作被拒的原因）
}

## 没有指定颜色。卡牌本身的值最大是 4<<4 | 14 = 78，用 255 当哨兵很安全。
const NO_COLOR := 255

const MAX_TEXT_BYTES := 256
const MAX_HAND_CARDS := 255


static func encode_play(card: int, chosen_color := -1) -> PackedByteArray:
	var color := NO_COLOR if chosen_color < 0 else clampi(chosen_color, 0, 4)
	return PackedByteArray([Action.PLAY, clampi(card, 0, 255), color])


static func encode_draw() -> PackedByteArray:
	return PackedByteArray([Action.DRAW])


static func encode_pass() -> PackedByteArray:
	return PackedByteArray([Action.PASS])


static func encode_say_uno() -> PackedByteArray:
	return PackedByteArray([Action.SAY_UNO])


static func encode_choose_color(color: int) -> PackedByteArray:
	return PackedByteArray([Action.CHOOSE_COLOR, clampi(color, 0, 4)])


static func encode_played(peer_id: int, card: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Action.PLAYED)
	buf.put_u16(peer_id & 0xFFFF)
	buf.put_u8(clampi(card, 0, 255))
	return buf.data_array


static func encode_drew(peer_id: int, count: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Action.DREW)
	buf.put_u16(peer_id & 0xFFFF)
	buf.put_u8(clampi(count, 0, 255))
	return buf.data_array


static func encode_log(text: String) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Action.LOG)
	_put_string(buf, text)
	return buf.data_array


## 手牌。**只允许单发**，见文件头的说明。
static func encode_hand(cards: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Action.SET_HAND)
	var count := mini(cards.size(), MAX_HAND_CARDS)
	buf.put_u8(count)
	for i in count:
		buf.put_u8(clampi(int(cards[i]), 0, 255))
	return buf.data_array


static func encode_reject(reason: String) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Action.REJECT)
	_put_string(buf, reason)
	return buf.data_array


static func _put_string(buf: StreamPeerBuffer, text: String) -> void:
	var bytes := text.to_utf8_buffer()
	if bytes.size() > MAX_TEXT_BYTES:
		bytes = bytes.slice(0, MAX_TEXT_BYTES)
	buf.put_u16(bytes.size())
	buf.put_data(bytes)


static func _get_string(buf: StreamPeerBuffer) -> Variant:
	if buf.get_available_bytes() < 2:
		return null
	var n := buf.get_u16()
	if n > MAX_TEXT_BYTES or buf.get_available_bytes() < n:
		return null
	return buf.get_utf8_string(n)


## 解码。任何非法输入都返回空字典，调用方丢弃即可，不要崩。
## 返回：{ action:int, card?:int, color?:int, peer_id?:int, count?:int, text?:String }
static func decode(data: PackedByteArray) -> Dictionary:
	if data.is_empty():
		return {}
	var action := data[0]

	match action:
		Action.PLAY:
			if data.size() < 3:
				return {}
			return {"action": action, "card": data[1], "color": data[2]}

		Action.DRAW:
			return {"action": action}

		Action.PASS:
			return {"action": action}

		Action.SAY_UNO:
			return {"action": action}

		Action.CHOOSE_COLOR:
			if data.size() < 2:
				return {}
			return {"action": action, "color": data[1]}

		Action.PLAYED:
			if data.size() < 4:
				return {}
			var b1 := StreamPeerBuffer.new()
			b1.data_array = data
			b1.seek(1)
			return {"action": action, "peer_id": b1.get_u16(), "card": b1.get_u8()}

		Action.DREW:
			if data.size() < 4:
				return {}
			var b2 := StreamPeerBuffer.new()
			b2.data_array = data
			b2.seek(1)
			return {"action": action, "peer_id": b2.get_u16(), "count": b2.get_u8()}

		Action.LOG:
			var b3 := StreamPeerBuffer.new()
			b3.data_array = data
			b3.seek(1)
			var text = _get_string(b3)
			if text == null:
				return {}
			return {"action": action, "text": String(text)}

		Action.SET_HAND:
			if data.size() < 2:
				return {}
			var b4 := StreamPeerBuffer.new()
			b4.data_array = data
			b4.seek(1)
			var count := b4.get_u8()
			if b4.get_available_bytes() < count:
				return {}
			var cards: Array = []
			for i in count:
				cards.append(b4.get_u8())
			return {"action": action, "cards": cards}

		Action.REJECT:
			var b5 := StreamPeerBuffer.new()
			b5.data_array = data
			b5.seek(1)
			var reason = _get_string(b5)
			if reason == null:
				return {}
			return {"action": action, "text": String(reason)}

	return {}
