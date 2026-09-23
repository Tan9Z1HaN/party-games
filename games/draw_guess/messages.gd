class_name DrawGuessMessages
extends RefCounted

## 你画我猜的小游戏报文。
##
## 房间层只负责把 payload 原样转给 MiniGame.on_player_input()，
## 具体含义由这里定义。所有报文第一个字节都是 Action。
##
## 笔迹报文（STROKE）刻意做成「动作字节 + 原始笔迹包」的直通形式，
## 权威端收到后不需要解码再编码就能转发，省一次拷贝。

enum Action {
	PICK_WORD = 1,     ## 画手选词：u8 index
	GUESS = 2,         ## 猜词：u16 字节数 + utf8
	STROKE = 3,        ## 笔迹片段：动作字节后面直接跟 StrokeCodec 的包
	MARK_CORRECT = 4,  ## 热座模式下画手标记某人猜对：u16 peer_id
	CLEAR = 5,         ## 请求清空画布
}

## 猜词文本上限。**按字符数截断，不能按字节截断**——
## UTF-8 里一个汉字 3 字节，从中间切开会产生半个字符，解码出来是乱码。
const MAX_GUESS_CHARS := 32
## 对应的字节上限，留给解码端做防御性校验
const MAX_GUESS_BYTES := 128


static func encode_pick_word(index: int) -> PackedByteArray:
	return PackedByteArray([Action.PICK_WORD, clampi(index, 0, 255)])


static func encode_guess(text: String) -> PackedByteArray:
	var trimmed := text.strip_edges()
	if trimmed.length() > MAX_GUESS_CHARS:
		trimmed = trimmed.substr(0, MAX_GUESS_CHARS)
	var bytes := trimmed.to_utf8_buffer()
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Action.GUESS)
	buf.put_u16(bytes.size())
	buf.put_data(bytes)
	return buf.data_array


static func encode_stroke(chunk: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([Action.STROKE])
	out.append_array(chunk)
	return out


static func encode_mark_correct(peer_id: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Action.MARK_CORRECT)
	buf.put_u16(peer_id & 0xFFFF)
	return buf.data_array


static func encode_clear() -> PackedByteArray:
	return PackedByteArray([Action.CLEAR])


## 解码。任何非法输入都返回空字典。
## 返回：{ action:int, index?:int, text?:String, peer_id?:int, payload?:PackedByteArray }
static func decode(data: PackedByteArray) -> Dictionary:
	if data.is_empty():
		return {}

	var action := data[0]
	match action:
		Action.PICK_WORD:
			if data.size() < 2:
				return {}
			return {"action": action, "index": data[1]}

		Action.GUESS:
			if data.size() < 3:
				return {}
			var buf := StreamPeerBuffer.new()
			buf.data_array = data
			buf.seek(1)
			var n := buf.get_u16()
			if n > MAX_GUESS_BYTES or buf.get_available_bytes() < n:
				return {}
			return {"action": action, "text": buf.get_utf8_string(n)}

		Action.STROKE:
			if data.size() <= 1:
				return {}
			return {"action": action, "payload": data.slice(1)}

		Action.MARK_CORRECT:
			if data.size() < 3:
				return {}
			var b2 := StreamPeerBuffer.new()
			b2.data_array = data
			b2.seek(1)
			return {"action": action, "peer_id": b2.get_u16()}

		Action.CLEAR:
			return {"action": action}

	return {}
