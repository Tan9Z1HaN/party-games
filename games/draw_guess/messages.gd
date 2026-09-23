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
	SET_WORD = 6,      ## 主机 -> 画手（单发）：本题答案，猜的人拿不到
	CHAT = 7,          ## 主机 -> 所有人：谁猜对了 / 猜得接近了
	SET_CANDIDATES = 8, ## 主机 -> 画手（单发）：三个候选词，画手要从中挑一个
}

## 猜词文本上限。**按字符数截断，不能按字节截断**——
## UTF-8 里一个汉字 3 字节，从中间切开会产生半个字符，解码出来是乱码。
const MAX_GUESS_CHARS := 32
## 对应的字节上限，留给解码端做防御性校验
const MAX_GUESS_BYTES := 128

## 通用短文本上限（词语、提示语）。编码时按字节截断，
## 只在词语/提示这种长度可控、且不介意尾部截断的场景使用。
const MAX_TEXT_BYTES := 512


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


## 只有画手会收到这条。**绝不能广播**——答案一旦下发到猜词者的机器上，
## 抓包就能看到，整局游戏就废了。
static func encode_set_word(word: String, category: String, difficulty: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Action.SET_WORD)
	_put_string(buf, word)
	_put_string(buf, category)
	buf.put_u8(difficulty & 0xFF)
	return buf.data_array


## kind: 0 = 猜对了，1 = 很接近
static func encode_chat(peer_id: int, kind: int, text: String) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Action.CHAT)
	buf.put_u16(peer_id & 0xFFFF)
	buf.put_u8(kind & 0xFF)
	_put_string(buf, text)
	return buf.data_array


## 候选词列表只发给画手：别人看到候选词等于拿到半个答案。
static func encode_candidates(words: PackedStringArray) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Action.SET_CANDIDATES)
	buf.put_u8(words.size() & 0xFF)
	for word in words:
		_put_string(buf, word)
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

		Action.SET_WORD:
			var b3 := StreamPeerBuffer.new()
			b3.data_array = data
			b3.seek(1)
			var word = _get_string(b3)
			var category = _get_string(b3)
			if word == null or category == null or b3.get_available_bytes() < 1:
				return {}
			return {
				"action": action,
				"word": String(word),
				"category": String(category),
				"difficulty": b3.get_u8(),
			}

		Action.CHAT:
			if data.size() < 4:
				return {}
			var b4 := StreamPeerBuffer.new()
			b4.data_array = data
			b4.seek(1)
			var who := b4.get_u16()
			var kind := b4.get_u8()
			var text = _get_string(b4)
			if text == null:
				return {}
			return {"action": action, "peer_id": who, "kind": kind, "text": String(text)}

		Action.SET_CANDIDATES:
			if data.size() < 2:
				return {}
			var b5 := StreamPeerBuffer.new()
			b5.data_array = data
			b5.seek(1)
			var count := b5.get_u8()
			var words := PackedStringArray()
			for i in count:
				var word = _get_string(b5)
				if word == null:
					return {}
				words.append(String(word))
			return {"action": action, "words": words}

	return {}
