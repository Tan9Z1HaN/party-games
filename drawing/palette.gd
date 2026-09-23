class_name DrawPalette
extends RefCounted

## 调色盘与笔宽。
##
## 颜色**不再用调色板索引传输**，而是直接传 RGB：
## 索引方案要支持丰富配色就得把整张色表在两端保持同步，
## 加一个颜色都得改协议。反正一个颜色只占 3 字节，而且每条笔迹只传一次。
##
## 笔宽改成无极调节：0~255 量化，映射到 WIDTH_MIN_PX~WIDTH_MAX_PX。
## 数值是「1080 宽画板上的基准像素」，渲染时按画板实际宽度等比缩放，
## 换机型后线条粗细观感一致。

const WIDTH_MIN_PX := 2.0
const WIDTH_MAX_PX := 64.0

## 橡皮的范围比笔大得多。擦除就是要快、要粗，
## 跟勾线笔共用一个上限的话，擦一块区域得来回蹭十几次。
const ERASER_MIN_PX := 24.0
const ERASER_MAX_PX := 220.0

const WIDTH_STEPS := 256

## 默认笔宽，手感上接近「中等偏细」
const DEFAULT_WIDTH_Q := 34

## 默认橡皮宽度，落在范围中段
const DEFAULT_ERASER_Q := 130

## 色相分几档。12 档 × 深浅两色 + 灰阶，够用又不至于挑花眼。
const HUE_STEPS := 12


## 量化笔宽 -> 像素。board_width 传画板实际宽度。
## eraser 为真时走橡皮那一套（粗得多）的范围。
static func width_px(width_q: int, board_width: float, eraser := false) -> float:
	var t := clampf(float(width_q) / float(WIDTH_STEPS - 1), 0.0, 1.0)
	var min_px := ERASER_MIN_PX if eraser else WIDTH_MIN_PX
	var max_px := ERASER_MAX_PX if eraser else WIDTH_MAX_PX
	return lerpf(min_px, max_px, t) * (board_width / 1080.0)


## 像素 -> 量化笔宽（反向，UI 显示用）
static func width_q_from_px(px: float, board_width: float, eraser := false) -> int:
	if board_width <= 0.0:
		return DEFAULT_WIDTH_Q
	var base := px * (1080.0 / board_width)
	var min_px := ERASER_MIN_PX if eraser else WIDTH_MIN_PX
	var max_px := ERASER_MAX_PX if eraser else WIDTH_MAX_PX
	var t := inverse_lerp(min_px, max_px, clampf(base, min_px, max_px))
	return clampi(int(round(t * float(WIDTH_STEPS - 1))), 0, WIDTH_STEPS - 1)


## 整张调色盘。顺序是「先灰阶，再按色相分组」，
## UI 直接按这个顺序铺格子，换行位置自然好看。
static func swatches() -> PackedColorArray:
	var out := PackedColorArray()

	# 灰阶：黑白加上四档灰，画草稿最常用
	for value in [0.0, 0.22, 0.42, 0.62, 0.82, 1.0]:
		out.append(Color(value, value, value))

	# 每个色相给「深」「饱和」「浅」三档
	for i in HUE_STEPS:
		var hue := float(i) / float(HUE_STEPS)
		out.append(Color.from_hsv(hue, 0.95, 0.45))
		out.append(Color.from_hsv(hue, 0.92, 0.78))
		out.append(Color.from_hsv(hue, 0.40, 1.0))

	return out
