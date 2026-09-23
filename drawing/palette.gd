class_name DrawPalette
extends RefCounted

## 调色板与笔宽定义。
##
## 颜色一律用**索引**在网络上传输（1 字节），不传 RGBA（4 字节）。
## 橡皮不用单独的索引，而是把笔画画成背景色。

## 橡皮专用索引。u8 足够，255 不会和 0~15 的真实颜色冲突。
const ERASER_INDEX := 255

## 16 色调色板
## 注意：这里必须用普通数组字面量，不能用 PackedColorArray(...)。
## 构造函数调用不是合法的常量表达式，会让 const 解析失败，
## 引用处以 "Could not resolve external class member" 的形式报错，很难定位。
const COLORS := [
	Color(0.106, 0.106, 0.122),  # 0  黑
	Color(1.000, 1.000, 1.000),  # 1  白
	Color(0.898, 0.282, 0.302),  # 2  红
	Color(0.969, 0.408, 0.031),  # 3  橙
	Color(1.000, 0.698, 0.141),  # 4  黄
	Color(0.275, 0.655, 0.345),  # 5  绿
	Color(0.071, 0.647, 0.580),  # 6  青
	Color(0.000, 0.569, 1.000),  # 7  蓝
	Color(0.431, 0.337, 0.812),  # 8  紫
	Color(0.914, 0.239, 0.510),  # 9  品红
	Color(0.553, 0.431, 0.388),  # 10 棕
	Color(0.961, 0.816, 0.773),  # 11 肤色
	Color(0.620, 0.620, 0.620),  # 12 灰
	Color(0.294, 0.333, 0.388),  # 13 深灰
	Color(0.714, 0.890, 0.420),  # 14 草绿
	Color(0.490, 0.827, 0.988),  # 15 天蓝
]

## 笔宽档位。数值是「1080 宽画板上的基准像素」，渲染时按画板实际宽度等比缩放，
## 这样换机型后线条粗细的观感是一致的。
const WIDTH_BASE := [4.0, 12.0, 28.0]


## 取颜色。索引越界自动取模；ERASER_INDEX 返回背景色。
static func color_of(index: int, background: Color) -> Color:
	if index == ERASER_INDEX:
		return background
	if COLORS.is_empty():
		return Color.BLACK
	return COLORS[posmod(index, COLORS.size())]


## 取笔宽（像素）。level 超出范围会被夹到合法区间。
static func width_of(level: int, board_width: float) -> float:
	var base: float = WIDTH_BASE[clampi(level, 0, WIDTH_BASE.size() - 1)]
	return base * (board_width / 1080.0)


## 该索引是否代表橡皮
static func is_eraser(index: int) -> bool:
	return index == ERASER_INDEX
