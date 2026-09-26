class_name TourMessages
extends RefCounted

## 环游中国的报文。
##
## **只有一种方向**：客户端把意图发给房主。反方向不发东西——
## 大富翁几乎没有隐藏信息（钱、地、等级、轮到谁，全是公开的），
## 所以房主只需要定期广播**完整状态快照**，客户端照着渲染就行。
## 这是它比 UNO 简单的地方：UNO 得单发手牌，这里不用。
##
## 所有报文都只有一个字节（动作号），因为这些动作都不带参数：
## 出哪张牌要说牌号，但"掷骰""买下"就是一句话。

enum Action {
	ROLL = 1,          ## 掷骰
	BUY = 2,           ## 买下当前这一格
	UPGRADE = 3,       ## 升级当前这一格
	DECLINE = 4,       ## 放弃这次机会
	PAY_FINE = 5,      ## 交罚款离开滞留区
	TAX_FLAT = 6,      ## 所得税：交固定值
	TAX_PERCENT = 7,   ## 所得税：按总资产比例交
}


static func encode_roll() -> PackedByteArray:
	return PackedByteArray([Action.ROLL])


static func encode_buy() -> PackedByteArray:
	return PackedByteArray([Action.BUY])


static func encode_upgrade() -> PackedByteArray:
	return PackedByteArray([Action.UPGRADE])


static func encode_decline() -> PackedByteArray:
	return PackedByteArray([Action.DECLINE])


static func encode_pay_fine() -> PackedByteArray:
	return PackedByteArray([Action.PAY_FINE])


static func encode_tax_flat() -> PackedByteArray:
	return PackedByteArray([Action.TAX_FLAT])


static func encode_tax_percent() -> PackedByteArray:
	return PackedByteArray([Action.TAX_PERCENT])


## 解码。任何非法输入都返回空字典，调用方丢掉即可。
static func decode(data: PackedByteArray) -> Dictionary:
	if data.is_empty():
		return {}
	var action := int(data[0])
	if action < Action.ROLL or action > Action.TAX_PERCENT:
		return {}
	return {"action": action}
