class_name StrokeCodec
extends RefCounted

## 笔迹的二进制编解码。
##
## 为什么不用 JSON / 不用传图片：
## - JSON 每个点要 20 字节以上，一秒几十个点直接压垮带宽
## - 传图片没法做「笔迹实时生长」，而且数据量大几十倍
##
## 本格式的设计要点：
## - 颜色用调色板索引（1 字节）而不是 RGBA（4 字节）
## - 点用**相对上一点的增量**编码，每轴 1 字节
## - **每个包自带一个绝对起始点**，解码不依赖跨包状态。
##   代价是每包多 4 字节，换来的是丢包/重排不会让整条笔迹错位。
##
## 单包布局：
##   u8  version
##   u8  flags        bit0=BEGIN bit1=END bit2=CLEAR
##   u16 stroke_id
##   u8  color_index
##   u8  width_q
##   u16 point_count
##   [point_count > 0 时] u16 x, u16 y   -> 本包第一个点的绝对坐标
##   [point_count - 1 组] i8 dx, i8 dy   -> 后续点相对前一点的增量
##
## 点数上限是 65535，但实际每包不会超过十几个点（见 DrawBoard.MAX_POINTS_PER_CHUNK）。

const VERSION := 1

const FLAG_BEGIN := 1 << 0
const FLAG_END := 1 << 1
const FLAG_CLEAR := 1 << 2

## 包头字节数
const HEADER_SIZE := 8

## 单包允许的最大点数。防御性上限，避免畸形包让解码端分配巨量内存。
const MAX_POINTS_PER_PACKET := 4096

## 单包最大字节数
const MAX_PACKET_BYTES := 16384


## 编码一段笔迹。
## points 使用板面量化坐标（0 ~ DrawBoard.BOARD_MAX）。
## 编码器会保证相邻点增量落在 i8 范围内——超出的插值由 DrawBoard 负责，
## 这里只做防御性夹取。
static func encode_chunk(
		stroke_id: int,
		flags: int,
		color_index: int,
		width_q: int,
		points: PackedVector2Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	var count := points.size()

	buf.put_u8(VERSION)
	buf.put_u8(flags & 0xFF)
	buf.put_u16(stroke_id & 0xFFFF)
	buf.put_u8(color_index & 0xFF)
	buf.put_u8(width_q & 0xFF)
	buf.put_u16(count & 0xFFFF)

	if count == 0:
		return buf.data_array

	var prev := _to_board_int(points[0])
	buf.put_u16(prev.x)
	buf.put_u16(prev.y)

	for i in range(1, count):
		var p := _to_board_int(points[i])
		buf.put_8(clampi(p.x - prev.x, -128, 127))
		buf.put_8(clampi(p.y - prev.y, -128, 127))
		prev = p

	return buf.data_array


## 解码一段笔迹。任何非法输入都返回空字典，绝不崩溃。
## 返回：{ flags, stroke_id, color_index, width_q, points: PackedVector2Array }
static func decode_chunk(data: PackedByteArray) -> Dictionary:
	if data.size() < HEADER_SIZE or data.size() > MAX_PACKET_BYTES:
		return {}

	var buf := StreamPeerBuffer.new()
	buf.data_array = data

	if buf.get_u8() != VERSION:
		return {}

	var flags := buf.get_u8()
	var stroke_id := buf.get_u16()
	var color_index := buf.get_u8()
	var width_q := buf.get_u8()
	var count := buf.get_u16()

	if count > MAX_POINTS_PER_PACKET:
		return {}

	var points := PackedVector2Array()
	if count > 0:
		if buf.get_available_bytes() < 4:
			return {}
		var prev := Vector2i(buf.get_u16(), buf.get_u16())
		points.append(Vector2(prev))

		for i in range(count - 1):
			if buf.get_available_bytes() < 2:
				return {}
			prev += Vector2i(buf.get_8(), buf.get_8())
			points.append(Vector2(prev))

	return {
		"flags": flags,
		"stroke_id": stroke_id,
		"color_index": color_index,
		"width_q": width_q,
		"points": points,
	}


## 把多段笔迹打包成一整块（用于重连者/中途加入者重建画布）。
## 布局：u8 version, u32 chunk_count, 然后每段 u32 长度 + 原始字节
static func encode_batch(chunks: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(VERSION)
	buf.put_u32(chunks.size())
	for chunk in chunks:
		var bytes: PackedByteArray = chunk
		buf.put_u32(bytes.size())
		buf.put_data(bytes)
	return buf.data_array


## 解出整块里的每一段。数据损坏时返回已成功解出的部分，不抛错。
static func decode_batch(data: PackedByteArray) -> Array:
	var out: Array = []
	if data.size() < 5:
		return out

	var buf := StreamPeerBuffer.new()
	buf.data_array = data

	if buf.get_u8() != VERSION:
		return out

	var count := buf.get_u32()
	if count > 8192:
		return out

	for i in range(count):
		if buf.get_available_bytes() < 4:
			return out
		var length := buf.get_u32()
		if length > MAX_PACKET_BYTES or buf.get_available_bytes() < int(length):
			return out
		out.append(buf.get_data(length)[1])

	return out


## Vector2 -> 板面整数坐标，并夹到 u16 范围内
static func _to_board_int(v: Vector2) -> Vector2i:
	return Vector2i(
		clampi(int(round(v.x)), 0, 65535),
		clampi(int(round(v.y)), 0, 65535)
	)
