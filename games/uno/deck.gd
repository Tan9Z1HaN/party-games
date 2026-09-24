class_name UnoDeck
extends RefCounted

## UNO 牌组（标准 108 张）。
##
## 一张牌用一个小整数表示：`card = 颜色 << 4 | 面值`。
## 颜色 0~4（红黄绿蓝 + 万能），面值 0~14：
##   0~9 数字牌，10 Skip，11 Reverse，12 Draw2，13 Wild，14 Wild4
##
## 用一个字节就装得下，之后联机传输直接发这个数，不用再设计一套格式。
## 位运算而不是除法和取模：一来没有整数除法的警告，二来意图更清楚。

enum C { RED, YELLOW, GREEN, BLUE, WILD }

enum F {
	N0, N1, N2, N3, N4, N5, N6, N7, N8, N9,
	SKIP, REVERSE, DRAW2, WILD, WILD4,
}

const FACE_STRIDE := 16

const COLOR_NAMES := ["红", "黄", "绿", "蓝", "万能"]
const FACE_NAMES := [
	"0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
	"跳过", "反转", "+2", "变色", "+4",
]


static func make(color: int, face: int) -> int:
	return (color << 4) | (face & 0x0F)


static func color_of(card: int) -> int:
	return card >> 4


static func face_of(card: int) -> int:
	return card & 0x0F


static func is_wild(card: int) -> bool:
	var face := face_of(card)
	return face == F.WILD or face == F.WILD4


static func is_number(card: int) -> bool:
	return face_of(card) <= F.N9


## 标准 108 张：每个颜色 0 一张、1~9 各两张、三种功能牌各两张，
## 外加 4 张变色和 4 张变色 +4。
static func build() -> Array[int]:
	var cards: Array[int] = []
	for color in [C.RED, C.YELLOW, C.GREEN, C.BLUE]:
		cards.append(make(color, F.N0))
		for face in range(F.N1, F.N9 + 1):
			cards.append(make(color, face))
			cards.append(make(color, face))
		for face in [F.SKIP, F.REVERSE, F.DRAW2]:
			cards.append(make(color, face))
			cards.append(make(color, face))
	for i in 4:
		cards.append(make(C.WILD, F.WILD))
		cards.append(make(C.WILD, F.WILD4))
	return cards


## 洗好的牌堆。seed_value 为 0 时用真随机，非 0 时用它复现——
## 测试要靠这个，不然出了 bug 根本没法重放。
##
## 不用 Array.shuffle()：那个走的是全局随机数发生器，注入不了种子。
static func shuffled(seed_value := 0) -> Array[int]:
	var cards := build()
	var rng := RandomNumberGenerator.new()
	if seed_value == 0:
		rng.randomize()
	else:
		rng.seed = seed_value
	for i in range(cards.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := cards[i]
		cards[i] = cards[j]
		cards[j] = tmp
	return cards


## 给测试输出和调试用。比如 红5、绿跳过、万能+4。
static func describe(card: int) -> String:
	var color := color_of(card)
	var face := face_of(card)
	if color == C.WILD:
		return FACE_NAMES[face]
	return "%s%s" % [COLOR_NAMES[color], FACE_NAMES[face]]
