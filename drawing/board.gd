class_name DrawBoard
extends Control

## 共享画板（冻结契约，勿改）。你画我猜与画猜接龙共用。
##
## 坐标约定：所有笔迹点一律使用**板面量化坐标**，
## 即把画板本地坐标按画板尺寸归一化后乘以 BOARD_MAX。
## 这样不同分辨率、不同机型的玩家看到的画完全一致。
## 量化精度 1/4096，在 1080 宽的画布上约 0.26 px，肉眼不可辨。
##
## 渲染与网络分离：本节点只负责画、以及产生笔迹片段。
## 广播由房间层订阅 stroke_chunk 信号后完成，本节点不直接碰网络。

const BOARD_MAX := 4095
const PALETTE_SIZE := 16
const WIDTH_LEVELS := 3

## 一段笔迹片段最多包含的点数，超过就切包。
## 每点增量编码后约 2 字节，配合这个上限可把单包控制在几十字节。
const MAX_POINTS_PER_CHUNK := 16

enum Tool { PEN, ERASER }

## 本地产生了新的笔迹片段，交给房间层广播
signal stroke_chunk(chunk: PackedByteArray)

## 画布被清空
signal canvas_cleared()


## 本地玩家是否有权作画（只有当前画手为 true）
func set_drawing_enabled(enabled: bool) -> void:
	push_error("DrawBoard.set_drawing_enabled() 未实现")


func is_drawing_enabled() -> bool:
	return false


func set_tool(tool: Tool) -> void:
	push_error("DrawBoard.set_tool() 未实现")


func get_tool() -> Tool:
	return Tool.PEN


## 调色板索引，0 ~ PALETTE_SIZE-1
func set_color_index(index: int) -> void:
	push_error("DrawBoard.set_color_index() 未实现")


func get_color_index() -> int:
	return 0


## 笔宽档位，0 ~ WIDTH_LEVELS-1
func set_width_level(level: int) -> void:
	push_error("DrawBoard.set_width_level() 未实现")


func get_width_level() -> int:
	return 1


## 应用一段远端笔迹（主机转发来的）。客户端与主机都调用。
## 内部必须做限流与合法性检查：非法数据静默丢弃，不要崩溃。
func apply_remote_chunk(chunk: PackedByteArray) -> void:
	push_error("DrawBoard.apply_remote_chunk() 未实现")


## 清空画布。只有权威端可以决定清空，再广播给所有人。
func clear_canvas() -> void:
	push_error("DrawBoard.clear_canvas() 未实现")


## 撤销最后一笔（只影响本地表现，是否需要广播由游戏层决定）
func undo_last_stroke() -> void:
	push_error("DrawBoard.undo_last_stroke() 未实现")


func get_stroke_count() -> int:
	return 0


## 把整块画布序列化。用于重连者 / 中途加入者重建画面。
func serialize_all() -> PackedByteArray:
	push_error("DrawBoard.serialize_all() 未实现")
	return PackedByteArray()


## 载入整块画布，对应 serialize_all()
func load_all(data: PackedByteArray) -> void:
	push_error("DrawBoard.load_all() 未实现")


## 控件局部坐标 -> 板面量化坐标
static func to_board(local_pos: Vector2, board_size: Vector2) -> Vector2i:
	var uv := (local_pos / board_size).clampf(0.0, 1.0)
	return Vector2i(
		int(round(uv.x * BOARD_MAX)),
		int(round(uv.y * BOARD_MAX))
	)


## 板面量化坐标 -> 控件局部坐标
static func from_board(p: Vector2i, board_size: Vector2) -> Vector2:
	return Vector2(float(p.x) / BOARD_MAX, float(p.y) / BOARD_MAX) * board_size
