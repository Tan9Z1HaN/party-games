class_name UnoAi
extends RefCounted

## 最简 AI 对手。
##
## 存在的意义有两个：
## 1. **单机试玩需要对手。** UNO 是隐藏信息的游戏——同屏热座会让所有人
##    看到彼此的手牌，根本没法玩。所以单机模式是对电脑，不是传手机。
## 2. 以后联机时玩家掉线，也用它托管（计划里那条「掉线 30 秒 AI 接管」）。
##
## 策略很朴素，但比「随便出一张」明显强：
##   - 有 +2 / 跳过就先出，给下家制造麻烦
##   - 万能牌留到最后，别当垃圾牌随手扔掉
##   - 优先出「自己手上颜色最多的那门」，这样出完之后还能接着出

## 选一张要出的牌。没有能出的返回 -1。
static func choose_card(rules: UnoRules, peer_id: int) -> int:
	var playable := rules.playable_cards(peer_id)
	if playable.is_empty():
		return -1

	var best := -1
	var best_score := -INF
	for card in playable:
		var score := _score(rules, peer_id, card)
		if score > best_score:
			best_score = score
			best = card
	return best


## 打出万能牌时选颜色：挑自己手上最多的那门。
static func choose_color(rules: UnoRules, peer_id: int) -> int:
	var counts := {
		UnoDeck.C.RED: 0, UnoDeck.C.YELLOW: 0,
		UnoDeck.C.GREEN: 0, UnoDeck.C.BLUE: 0,
	}
	for card in rules.hand_of(peer_id):
		var color := UnoDeck.color_of(card)
		if color != UnoDeck.C.WILD:
			counts[color] = int(counts[color]) + 1

	var best := UnoDeck.C.RED
	var best_count := -1
	for color in counts:
		if int(counts[color]) > best_count:
			best_count = int(counts[color])
			best = color
	return best


static func _score(rules: UnoRules, peer_id: int, card: int) -> float:
	var face := UnoDeck.face_of(card)
	var score := 0.0

	match face:
		UnoDeck.F.WILD, UnoDeck.F.WILD4:
			score -= 50.0          # 翻盘牌，留到最后
		UnoDeck.F.DRAW2:
			score += 12.0
		UnoDeck.F.SKIP:
			score += 10.0
		UnoDeck.F.REVERSE:
			score += 8.0
		_:
			score += float(face) * 0.1

	# 出完这张之后，自己在这门颜色上还有牌可跟吗？有就加分。
	var keep := UnoDeck.color_of(card)
	if keep != UnoDeck.C.WILD:
		for other in rules.hand_of(peer_id):
			if other != card and UnoDeck.color_of(other) == keep:
				score += 3.0
				break

	return score
