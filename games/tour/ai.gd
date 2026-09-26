class_name TourAi
extends RefCounted

## 大富翁的电脑对手。
##
## 只做贪心，不做估值搜索——它的作用是让单机能玩、掉线能托管，
## 不是来赢的。真正好玩的是和朋友互相坑，AI 只要不犯蠢就够了。
##
## 判断都留一点余量：钱刚好够买就全花光，下一脚踩到别人地上就直接出局了。

## 买地后至少要留这么多现金。
##
## **别设太高**：这是破产制，钱必须流动起来——买地、升级、然后被别人踩到。
## 一开始设 300/500 的时候，AI 攒着一堆现金守着 1 级的地，租金低得谁都
## 破不了产，4 个人打了 390 轮还没完；压到 150 之后节奏才正常。
const BUY_RESERVE := 150
## 升级后至少要留这么多
const UPGRADE_RESERVE := 150


## 按当前局面挑一个动作。返回 TourRules.Action。
static func choose(rules: TourRules, peer_id: int) -> int:
	if peer_id != rules.current_player():
		return TourRules.Action.PASS

	if rules.phase() == TourRules.Phase.DECIDING:
		var cell := rules.pending_cell()
		if rules.decision() == TourRules.Decision.TAX:
			# 哪个便宜交哪个（rules 里已经算好了）
			var options := rules.tax_options(peer_id)
			return TourRules.Action.TAX_PERCENT \
				if String(options["cheaper"]) == "percent" else TourRules.Action.TAX_FLAT
		if rules.decision() == TourRules.Decision.BUY:
			if rules.cash_of(peer_id) - rules.buy_price(cell) >= BUY_RESERVE:
				return TourRules.Action.BUY
			return TourRules.Action.PASS

		var cost := rules.upgrade_price(cell)
		if cost > 0 and rules.cash_of(peer_id) - cost >= UPGRADE_RESERVE:
			return TourRules.Action.UPGRADE
		return TourRules.Action.PASS

	# 手头宽裕就把罚款交了，不浪费一个回合
	if rules.skip_of(peer_id) > 0 \
			and rules.cash_of(peer_id) >= TourRules.JAIL_FINE * 3:
		return TourRules.Action.PAY_FINE

	return TourRules.Action.ROLL


## 把动作执行掉。返回执行结果，方便调用方记日志或判断是否卡住。
static func act(rules: TourRules, peer_id: int) -> Dictionary:
	match choose(rules, peer_id):
		TourRules.Action.BUY:
			return rules.buy(peer_id)
		TourRules.Action.UPGRADE:
			return rules.upgrade(peer_id)
		TourRules.Action.PAY_FINE:
			return rules.pay_fine(peer_id)
		TourRules.Action.TAX_FLAT:
			return rules.pay_tax_flat(peer_id)
		TourRules.Action.TAX_PERCENT:
			return rules.pay_tax_percent(peer_id)
		TourRules.Action.PASS:
			return rules.decline(peer_id)
	return rules.roll(peer_id)
