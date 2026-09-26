class_name TourCards
extends RefCounted

## 机会 / 命运卡片。
##
## 两个牌堆共用同一份效果定义，只是洗牌时分开洗——文案不同、效果类型相同，
## 没必要写两套。
##
## 文案的三条硬性要求：
##   1. **一行读完**：超过 12 个字，手机上一行放不下，玩家就不看了
##   2. **中性无害**：不写调侃政策、政府部门、地域、灾害的内容。
##      熟人间好笑的梗，装到应用商店里就是风险，何况聚会里常有生人
##   3. **效果和文案对得上**：写「前进」就真的前进，别让玩家记规则

enum Effect {
	GAIN,      ## 收钱
	PAY,       ## 付钱
	MOVE,      ## 前进/后退（value 正数前进、负数后退）
	SKIP,      ## 暂停几次
	TO_JAIL,   ## 直接进滞留区
}

## 偏收益的，归"机会"堆
const CHANCE := [
	{"text": "高铁提速，前进 3 格", "effect": Effect.MOVE, "value": 3},
	{"text": "网红打卡火了，收 200", "effect": Effect.GAIN, "value": 200},
	{"text": "探店接到广告，收 300", "effect": Effect.GAIN, "value": 300},
	{"text": "退了一张机票，收 100", "effect": Effect.GAIN, "value": 100},
	{"text": "顺路拼车，前进 2 格", "effect": Effect.MOVE, "value": 2},
	{"text": "押金退回来了，收 150", "effect": Effect.GAIN, "value": 150},
	{"text": "抢到特价机票，收 250", "effect": Effect.GAIN, "value": 250},
	{"text": "夜班车直达，前进 4 格", "effect": Effect.MOVE, "value": 4},
	{"text": "淡季机票打折，收 80", "effect": Effect.GAIN, "value": 80},
	{"text": "朋友还了借款，收 250", "effect": Effect.GAIN, "value": 250},
	{"text": "免票入园，前进 1 格", "effect": Effect.MOVE, "value": 1},
	{"text": "赶上换乘，前进 2 格", "effect": Effect.MOVE, "value": 2},
]

## 偏损失的，归"命运"堆
const FATE := [
	{"text": "走错航站楼，后退 2 格", "effect": Effect.MOVE, "value": -2},
	{"text": "直播带货翻车，付 150", "effect": Effect.PAY, "value": 150},
	{"text": "景区排队，暂停一次", "effect": Effect.SKIP, "value": 1},
	{"text": "行李超重，付 100", "effect": Effect.PAY, "value": 100},
	{"text": "天气延误，直接进滞留区", "effect": Effect.TO_JAIL, "value": 0},
	{"text": "手机摔了，换屏付 200", "effect": Effect.PAY, "value": 200},
	{"text": "坐过了站，后退 3 格", "effect": Effect.MOVE, "value": -3},
	{"text": "民宿临时涨价，付 120", "effect": Effect.PAY, "value": 120},
	{"text": "打车绕了远路，付 80", "effect": Effect.PAY, "value": 80},
	{"text": "忘带充电宝，付 60", "effect": Effect.PAY, "value": 60},
	{"text": "遇上交通管制，暂停一次", "effect": Effect.SKIP, "value": 1},
	{"text": "买错门票日期，付 150", "effect": Effect.PAY, "value": 150},
	{"text": "排错窗口，后退 1 格", "effect": Effect.MOVE, "value": -1},
]


static func deck_for(is_chance: bool) -> Array:
	return (CHANCE.duplicate(true) if is_chance else FATE.duplicate(true))
