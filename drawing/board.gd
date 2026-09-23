class_name DrawBoard
extends Control

## 共享画板。你画我猜与画猜接龙共用。
##
## 坐标约定：所有笔迹点一律使用**板面量化坐标**，
## 即把画板本地坐标按画板尺寸归一化后乘以 BOARD_MAX。
## 这样不同分辨率、不同机型的玩家看到的画完全一致。
## 量化精度 1/4096，在 1080 宽的画布上约 0.26 px，肉眼不可辨。
##
## 渲染与网络分离：本节点只负责画、以及产生笔迹片段。
## 广播由房间层订阅 stroke_chunk 信号后完成，本节点不直接碰网络。
##
## 性能说明：笔迹只存在内存里，靠 _draw() 一次性重绘。
## Godot 只在 CanvasItem 变脏时才调 _draw()，所以静止的笔迹**不产生每帧开销**。
##
## 注意：调用方必须保证画板保持固定宽高比（4:3，用 AspectRatioContainer），
## 否则不同机型的画板形状不同，同一份量化坐标会被拉伸成不同的样子。

const BOARD_MAX := 4095

enum Tool { PEN, ERASER }

## 本地产生了新的笔迹片段，交给房间层广播
signal stroke_chunk(chunk: PackedByteArray)

## 画布被清空（本地主动清空时发出，收到远端清空时不发，避免回环）
signal canvas_cleared()

## 抽稀阈值（板面单位）。相邻采样点距离小于它就直接丢弃，避免点数量爆炸。
const MIN_POINT_DISTANCE := 5.0

## 单步增量上限。超过就在两点之间插值，保证 i8 增量编码不失真。
const MAX_STEP := 100.0

## 最长攒多久就把没发出去的点发一段（秒）。
## 决定远端看到笔迹"生长"的流畅度，太大就变成一卡一卡的。
const CHUNK_INTERVAL := 0.05

## 一段笔迹片段最多包含的点数
const MAX_POINTS_PER_CHUNK := 16

## 背景色。橡皮不是真的擦除，而是用背景色画一条线。
## 这个取巧在矢量笔迹方案下最省事，代价是之后没法"恢复被擦掉的部分"。
var background_color: Color = Color.WHITE

var _tool: Tool = Tool.PEN
var _color: Color = Color(0.1, 0.1, 0.12)
var _width_q: int = DrawPalette.DEFAULT_WIDTH_Q
var _drawing_enabled := false

## 已完成的笔迹：[{ id, color: Color, width_q:int, eraser:bool, points }]
var _strokes: Array = []

## 正在画的那一笔
var _active := false
var _active_id := 0
var _active_color := Color.BLACK
var _active_width := 0
var _active_eraser := false
var _active_points := PackedVector2Array()

## 已采集但还没发出去的点
var _pending := PackedVector2Array()
var _pending_since := 0.0
var _stroke_sent_any := false
var _has_pending_chunk := false

var _next_stroke_id := 1
var _last_point := Vector2i.ZERO
var _pressing := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	if not _has_pending_chunk:
		return
	_pending_since += delta
	if _pending_since >= CHUNK_INTERVAL:
		_flush(false)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), background_color, true)
	var board_size := size
	for stroke in _strokes:
		_draw_stroke(stroke, board_size)
	if _active:
		_draw_stroke({
			"color": _active_color,
			"width_q": _active_width,
			"eraser": _active_eraser,
			"points": _active_points,
		}, board_size)


func _draw_stroke(stroke: Dictionary, board_size: Vector2) -> void:
	var points: PackedVector2Array = stroke["points"]
	if points.is_empty():
		return

	var color: Color = background_color if bool(stroke.get("eraser", false)) else stroke["color"]
	var width := DrawPalette.width_px(int(stroke["width_q"]), board_size.x)

	if points.size() == 1:
		draw_circle(from_board(Vector2i(points[0]), board_size), width * 0.5, color)
		return

	var local := PackedVector2Array()
	local.resize(points.size())
	for i in points.size():
		local[i] = from_board(Vector2i(points[i]), board_size)

	draw_polyline(local, color, width, true)
	# 圆头端点，否则快速甩笔的线条两端是方的，很出戏
	draw_circle(local[0], width * 0.5, color)
	draw_circle(local[local.size() - 1], width * 0.5, color)


# ---------------------------------------------------------------- 本地输入

func _gui_input(event: InputEvent) -> void:
	if not _drawing_enabled:
		return

	if event is InputEventScreenTouch:
		if event.pressed:
			_begin_stroke(event.position)
		else:
			_end_stroke()
		accept_event()
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_begin_stroke(event.position)
			else:
				_end_stroke()
			accept_event()
		return

	if event is InputEventScreenDrag or event is InputEventMouseMotion:
		if _pressing:
			_extend_stroke(event.position)
			accept_event()
		return


func _begin_stroke(local_pos: Vector2) -> void:
	_pressing = true
	_active = true
	_active_id = _next_stroke_id
	_next_stroke_id = (_next_stroke_id % 0xFFFF) + 1
	_active_color = _color
	_active_width = _width_q
	_active_eraser = _tool == Tool.ERASER

	var p := to_board(local_pos, size)
	_last_point = p
	_active_points = PackedVector2Array([Vector2(p)])
	_pending = PackedVector2Array([Vector2(p)])
	_pending_since = 0.0
	_stroke_sent_any = false
	_has_pending_chunk = true

	queue_redraw()


func _extend_stroke(local_pos: Vector2) -> void:
	if not _active:
		return

	var target := to_board(local_pos, size)
	var dist := Vector2(target - _last_point).length()
	if dist < MIN_POINT_DISTANCE:
		return

	# 插值：保证相邻两点的增量不超过 i8 能表示的范围。
	# 快速甩笔时一次移动可能几百个板面单位，不插值就会被夹取，线条直接跑偏。
	var steps := maxi(1, int(ceil(dist / MAX_STEP)))
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		var p := Vector2i(Vector2(_last_point).lerp(Vector2(target), t).round())
		_active_points.append(Vector2(p))
		_pending.append(Vector2(p))

	_last_point = target
	_has_pending_chunk = true

	if _pending.size() >= MAX_POINTS_PER_CHUNK:
		_flush(false)

	queue_redraw()


func _end_stroke() -> void:
	if not _pressing:
		return
	_pressing = false
	_flush(true)

	if _active_points.size() > 0:
		_strokes.append({
			"id": _active_id,
			"color": _active_color,
			"width_q": _active_width,
			"eraser": _active_eraser,
			"points": _active_points,
		})

	_active = false
	_active_points = PackedVector2Array()
	queue_redraw()


## 把攒着的点发一段出去。is_end 为真时带上 END 标志。
func _flush(is_end: bool) -> void:
	if not _active:
		return

	if _pending.is_empty():
		if is_end and _stroke_sent_any:
			stroke_chunk.emit(StrokeCodec.encode_chunk(
				_active_id, _active_flags(0, true), _active_color, _active_width,
				PackedVector2Array()))
			_has_pending_chunk = false
		return

	stroke_chunk.emit(StrokeCodec.encode_chunk(
		_active_id, _active_flags(0, is_end), _active_color, _active_width, _pending))

	_stroke_sent_any = true
	_pending = PackedVector2Array()
	_pending_since = 0.0
	_has_pending_chunk = false


func _active_flags(extra: int, is_end: bool) -> int:
	var flags := extra
	if not _stroke_sent_any:
		flags |= StrokeCodec.FLAG_BEGIN
	if is_end:
		flags |= StrokeCodec.FLAG_END
	if _active_eraser:
		flags |= StrokeCodec.FLAG_ERASER
	return flags


# ---------------------------------------------------------------- 公开接口

## 本地玩家是否有权作画（只有当前画手为 true）
func set_drawing_enabled(enabled: bool) -> void:
	_drawing_enabled = enabled
	if not enabled and _pressing:
		_end_stroke()


func is_drawing_enabled() -> bool:
	return _drawing_enabled


func set_tool(tool: Tool) -> void:
	_tool = tool


func get_tool() -> Tool:
	return _tool


func set_color(color: Color) -> void:
	_color = color
	_tool = Tool.PEN


func get_color() -> Color:
	return _color


## 笔宽，0 ~ DrawPalette.WIDTH_STEPS-1 的量化值。无极调节。
func set_width_level(quantized: int) -> void:
	_width_q = clampi(quantized, 0, DrawPalette.WIDTH_STEPS - 1)


func get_width_level() -> int:
	return _width_q


## 应用一段远端笔迹。非法数据静默丢弃，不要崩溃。
func apply_remote_chunk(chunk: PackedByteArray) -> void:
	if chunk.size() < StrokeCodec.HEADER_SIZE or chunk.size() > StrokeCodec.MAX_PACKET_BYTES:
		return
	var decoded := StrokeCodec.decode_chunk(chunk)
	if decoded.is_empty():
		return
	_ingest(decoded)


## 清空画布。只有权威端可以决定清空，再广播给所有人。
func clear_canvas() -> void:
	_apply_clear()
	canvas_cleared.emit()


## 撤销最后一笔。只影响本地表现；要不要广播由游戏层决定
## （直接广播"撤销"在多端会不一致，稳妥做法是清空后重放）。
func undo_last_stroke() -> void:
	if _active:
		_active = false
		_active_points = PackedVector2Array()
		_pending = PackedVector2Array()
		_has_pending_chunk = false
	elif not _strokes.is_empty():
		_strokes.pop_back()
	queue_redraw()


func get_stroke_count() -> int:
	return _strokes.size()


func is_stroke_in_progress() -> bool:
	return _active


## 把整块画布序列化。用于重连者 / 中途加入者重建画面。
func serialize_all() -> PackedByteArray:
	var chunks: Array = []
	for stroke in _strokes:
		var flags := StrokeCodec.FLAG_BEGIN | StrokeCodec.FLAG_END
		if bool(stroke.get("eraser", false)):
			flags |= StrokeCodec.FLAG_ERASER
		chunks.append(StrokeCodec.encode_chunk(
			stroke["id"], flags, stroke["color"], stroke["width_q"], stroke["points"]))
	return StrokeCodec.encode_batch(chunks)


## 载入整块画布，对应 serialize_all()
func load_all(data: PackedByteArray) -> void:
	_apply_clear()
	for chunk in StrokeCodec.decode_batch(data):
		apply_remote_chunk(chunk)
	queue_redraw()


# ---------------------------------------------------------------- 内部工具

func _ingest(decoded: Dictionary) -> void:
	var flags: int = decoded["flags"]
	if flags & StrokeCodec.FLAG_CLEAR:
		_apply_clear()
		return

	var id: int = decoded["stroke_id"]
	var points: PackedVector2Array = decoded["points"]

	if flags & StrokeCodec.FLAG_BEGIN:
		_strokes.append({
			"id": id,
			"color": decoded["color"],
			"width_q": decoded["width_q"],
			"eraser": bool(flags & StrokeCodec.FLAG_ERASER),
			"points": points,
		})
	elif not points.is_empty():
		# 续包：按 id 找那一条，找不到就丢掉。
		# 凭空出现的续包（比如漏了 BEGIN）不猜，直接忽略更安全。
		var idx := _find_stroke_index(id)
		if idx >= 0:
			var merged: PackedVector2Array = _strokes[idx]["points"]
			merged.append_array(points)
			_strokes[idx]["points"] = merged
		else:
			return
	else:
		return

	queue_redraw()


func _find_stroke_index(id: int) -> int:
	# 从后往前找，最近的一条最可能命中
	for i in range(_strokes.size() - 1, -1, -1):
		if int(_strokes[i]["id"]) == id:
			return i
	return -1


func _apply_clear() -> void:
	_strokes.clear()
	_active = false
	_active_points = PackedVector2Array()
	_pending = PackedVector2Array()
	_has_pending_chunk = false
	queue_redraw()


## 控件局部坐标 -> 板面量化坐标
static func to_board(local_pos: Vector2, board_size: Vector2) -> Vector2i:
	if board_size.x <= 0.0 or board_size.y <= 0.0:
		return Vector2i.ZERO
	var uv := (local_pos / board_size).clampf(0.0, 1.0)
	return Vector2i(
		int(round(uv.x * BOARD_MAX)),
		int(round(uv.y * BOARD_MAX))
	)


## 板面量化坐标 -> 控件局部坐标
static func from_board(p: Vector2i, board_size: Vector2) -> Vector2:
	return Vector2(float(p.x) / BOARD_MAX, float(p.y) / BOARD_MAX) * board_size
