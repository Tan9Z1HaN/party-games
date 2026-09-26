class_name TourBoard
extends RefCounted

## 棋盘：40 格环形，城市取自中国各地。
##
## 结构照抄经典大富翁（12 个特殊格 + 28 个可购买格），因为它的节奏是被
## 验证过的：一开始每两三格就有事发生，越往后越密。
##
## 一格就用它在环上的下标（0~39）表示，所有信息在下面这张表里查——
## 和 UNO 一样，规则层不自己编数据。
##
## 特殊格的位置（0/10/20/30 是四条边的端点、5/15/25/35 是高铁站）
## 也照抄经典：「每边 10 格、第 10 格是特殊格」是玩家记路的锚点。
##
## 价格和分组的来由见 docs/环游中国（大富翁玩法）规划.md，别随手改数字：
## 组的格子数、价格梯度、特殊格位置三者是一套的。

enum Kind {
	GO,        ## 出发
	CITY,      ## 城市：可买可升级，最多 4 级
	STATION,   ## 高铁枢纽：可买可升级，最多 2 级
	UTILITY,   ## 公用事业：可买可升级，最多 2 级
	CHANCE,    ## 机会
	FATE,      ## 命运
	TAX,       ## 税
	VISIT,     ## 滞留区（路过/探访，没事）
	TO_JAIL,   ## 进滞留区
	REST,      ## 休息区
}

## 每升一级租金翻几倍。
##
## 这个系数决定"多久能分出胜负"。破产制之下它得够狠：太温和的话，
## 一圈 +200 的收入会盖过过路费，大家都越来越富，一局能拖几百轮
## （实测 2.2 时 4 人要打 390 轮）。3.0 配 1000 起始资金刚好。
const RENT_STEP := 3.0

## 1 级地的租金 = 地价 × 这个系数。
##
## 也别小看它：破产制之下地大多停在 1~2 级（升级要钱），所以**这一项
## 才是过路费的主力**。0.1 的时候一局要打两三百轮，玩家早就跑了。
const RENT_BASE := 0.25

## 组名。同组集齐 → 租金翻倍。
const GROUPS := [
	"华南·暖冬", "华南·山水", "西北", "华中",
	"华东", "西南·网红", "华北·东北", "一线",
]

## 滞留格（第 10 格）。进滞留区是移到这一格，不是另开一个格子。
const JAIL_CELL := 10
## 每边 10 格
const SIDE := 10

## 每一格：name 全名（日志和弹窗用）/ kind 类别 / group 组号（-1 不属于任何组）
## / price 地价 / amount 税额 / short 格子上的短名（只有全名超过 4 个字时才写）
##
## **格子上只放短名**：一格在 1080 宽的竖屏上只有 98 像素，四个字已经是极限，
## 五个字就读不出来了。全名留给弹窗和日志。
const CELLS := [
	{"name": "出发", "kind": Kind.GO, "group": -1, "price": 0, "amount": 0},
	{"name": "三亚", "kind": Kind.CITY, "group": 0, "price": 60, "amount": 0},
	{"name": "命运", "kind": Kind.FATE, "group": -1, "price": 0, "amount": 0},
	{"name": "海口", "kind": Kind.CITY, "group": 0, "price": 80, "amount": 0},
	{"name": "个人所得税", "short": "所得税", "kind": Kind.TAX, "group": -1, "price": 0, "amount": 200},
	{"name": "北京南站", "kind": Kind.STATION, "group": -1, "price": 200, "amount": 0},
	{"name": "桂林", "kind": Kind.CITY, "group": 1, "price": 100, "amount": 0},
	{"name": "机会", "kind": Kind.CHANCE, "group": -1, "price": 0, "amount": 0},
	{"name": "厦门", "kind": Kind.CITY, "group": 1, "price": 120, "amount": 0},
	{"name": "贵阳", "kind": Kind.CITY, "group": 1, "price": 140, "amount": 0},
	{"name": "滞留区", "kind": Kind.VISIT, "group": -1, "price": 0, "amount": 0},
	{"name": "乌鲁木齐", "kind": Kind.CITY, "group": 2, "price": 160, "amount": 0},
	{"name": "国家电网", "kind": Kind.UTILITY, "group": -1, "price": 150, "amount": 0},
	{"name": "兰州", "kind": Kind.CITY, "group": 2, "price": 180, "amount": 0},
	{"name": "西安", "kind": Kind.CITY, "group": 2, "price": 200, "amount": 0},
	{"name": "上海虹桥站", "short": "虹桥", "kind": Kind.STATION, "group": -1, "price": 200, "amount": 0},
	{"name": "长沙", "kind": Kind.CITY, "group": 3, "price": 200, "amount": 0},
	{"name": "命运", "kind": Kind.FATE, "group": -1, "price": 0, "amount": 0},
	{"name": "郑州", "kind": Kind.CITY, "group": 3, "price": 220, "amount": 0},
	{"name": "武汉", "kind": Kind.CITY, "group": 3, "price": 240, "amount": 0},
	{"name": "休息区", "kind": Kind.REST, "group": -1, "price": 0, "amount": 0},
	{"name": "苏州", "kind": Kind.CITY, "group": 4, "price": 240, "amount": 0},
	{"name": "机会", "kind": Kind.CHANCE, "group": -1, "price": 0, "amount": 0},
	{"name": "南京", "kind": Kind.CITY, "group": 4, "price": 260, "amount": 0},
	{"name": "杭州", "kind": Kind.CITY, "group": 4, "price": 280, "amount": 0},
	{"name": "广州南站", "kind": Kind.STATION, "group": -1, "price": 200, "amount": 0},
	{"name": "成都", "kind": Kind.CITY, "group": 5, "price": 280, "amount": 0},
	{"name": "重庆", "kind": Kind.CITY, "group": 5, "price": 300, "amount": 0},
	{"name": "南水北调", "kind": Kind.UTILITY, "group": -1, "price": 150, "amount": 0},
	{"name": "天津", "kind": Kind.CITY, "group": 6, "price": 300, "amount": 0},
	{"name": "进滞留区", "kind": Kind.TO_JAIL, "group": -1, "price": 0, "amount": 0},
	{"name": "沈阳", "kind": Kind.CITY, "group": 6, "price": 320, "amount": 0},
	{"name": "哈尔滨", "kind": Kind.CITY, "group": 6, "price": 340, "amount": 0},
	{"name": "命运", "kind": Kind.FATE, "group": -1, "price": 0, "amount": 0},
	{"name": "广州", "kind": Kind.CITY, "group": 7, "price": 360, "amount": 0},
	{"name": "成都东站", "kind": Kind.STATION, "group": -1, "price": 200, "amount": 0},
	{"name": "机会", "kind": Kind.CHANCE, "group": -1, "price": 0, "amount": 0},
	{"name": "上海", "kind": Kind.CITY, "group": 7, "price": 380, "amount": 0},
	{"name": "奢侈税", "kind": Kind.TAX, "group": -1, "price": 0, "amount": 100},
	{"name": "北京", "kind": Kind.CITY, "group": 7, "price": 400, "amount": 0},
]


static func size() -> int:
	return CELLS.size()


static func name_of(cell: int) -> String:
	if not valid(cell):
		return "?"
	return String(CELLS[cell]["name"])


## 画在格子上的短名。没写就是全名。
static func short_name_of(cell: int) -> String:
	if not valid(cell):
		return "?"
	return String(CELLS[cell].get("short", CELLS[cell]["name"]))


## 40 格在棋盘上的坐标：格子是 11x11 网格里的一圈。
##
## 走法照抄经典大富翁：0 号在右下角，往左走底边、往上走左边、往右走顶边、
## 往下走右边。所以 0/10/20/30 正好是四个角。
##
## area 是整块棋盘的尺寸。**不要求是正方形**：手机竖屏上把棋盘拉长成矩形，
## 格子的高度就更大，名字更好放，纵向也不浪费——经典棋盘是方的，
## 但那是给桌面设计的。
static func cell_rect(cell: int, area: Vector2) -> Rect2:
	var unit := area / 11.0
	var col := 0
	var row := 0
	if cell <= 10:            # 底边：从右下角往左
		col = 10 - cell
		row = 10
	elif cell <= 20:          # 左边：从下往上
		col = 0
		row = 10 - (cell - 10)
	elif cell <= 30:          # 顶边：从左往右
		col = cell - 20
		row = 0
	else:                     # 右边：从上往下
		col = 10
		row = cell - 30
	return Rect2(Vector2(float(col), float(row)) * unit, unit)


static func kind_of(cell: int) -> int:
	if not valid(cell):
		return Kind.GO
	return int(CELLS[cell]["kind"])


static func group_of(cell: int) -> int:
	if not valid(cell):
		return -1
	return int(CELLS[cell]["group"])


static func price_of(cell: int) -> int:
	if not valid(cell):
		return 0
	return int(CELLS[cell]["price"])


static func amount_of(cell: int) -> int:
	if not valid(cell):
		return 0
	return int(CELLS[cell]["amount"])


static func valid(cell: int) -> bool:
	return cell >= 0 and cell < CELLS.size()


## 能不能买：城市、高铁站、公用事业。
static func is_purchasable(cell: int) -> bool:
	var kind := kind_of(cell)
	return kind == Kind.CITY or kind == Kind.STATION or kind == Kind.UTILITY


## 最高能升到几级。城市 4 级，车站和公用事业 2 级。
static func max_level(cell: int) -> int:
	match kind_of(cell):
		Kind.CITY:
			return 4
		Kind.STATION, Kind.UTILITY:
			return 2
	return 0


## 某个组里的所有格子。用来判断"整组是不是都归同一个人"。
static func cells_in_group(group: int) -> Array[int]:
	var out: Array[int] = []
	for cell in CELLS.size():
		if group_of(cell) == group and is_purchasable(cell):
			out.append(cell)
	return out


## 从 level 级升到 level+1 要多少钱。地价的一半。
static func upgrade_cost(cell: int, level: int) -> int:
	if level < 1 or level >= max_level(cell):
		return 0
	return roundi(float(price_of(cell)) * 0.5)


## 过路费。用公式算而不是手写 22 张表，这样调价格只要改系数。
##
##   城市：地价 × 0.1，每升一级 × 2.2
##   车站：100 / 200 两级固定
##   公用事业：100 / 250
##   整组归同一个人时翻倍
static func rent_of(cell: int, level: int, monopoly := false) -> int:
	if not is_purchasable(cell) or level < 1:
		return 0
	var base := 0
	match kind_of(cell):
		Kind.CITY:
			base = roundi(float(price_of(cell)) * RENT_BASE * pow(RENT_STEP, float(level - 1)))
		Kind.STATION:
			base = 250 if level == 1 else 500
		Kind.UTILITY:
			base = 200 if level == 1 else 500
	if monopoly and kind_of(cell) == Kind.CITY:
		base *= 2
	return base
