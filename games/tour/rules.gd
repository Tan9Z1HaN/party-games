class_name TourRules
extends RefCounted

## 大富翁玩法的规则引擎。**纯逻辑**，不碰界面、不碰网络。
##
## **胜利条件：把别人搞破产**，最后只剩一个人没出局，他赢。
## 这是经典玩法——比起"走满几轮比资产"，破产制才有真正的博弈：
## 买哪块、升到几级、敢不敢把钱花光，每一步都在赌。
##
## 代价是可能拖长。所以留了一个可选的回合上限（默认不限）当保险丝：
## 真拖住了才按资产结算，正常局不该看到它。
## 设计取舍见 docs/环游中国（大富翁玩法）规划.md。
##
## 和 UnoRules 一个路子：所有判定都在这里，界面和网络层只读结果。
## 骰子走可注入的随机种子，测试才复现得了「走到某格 → 买到 → 落到对手
## 地上 → 破产」这种具体情境。

enum Phase {
	AWAIT_ROLL,   ## 等当前玩家掷骰
	DECIDING,     ## 等当前玩家决定买 / 升级 / 放弃
	FINISHED,
}

enum Decision { NONE, BUY, UPGRADE, TAX }

## 动作的结果，界面和 AI 用它决定下一步
enum Action { ROLL, BUY, UPGRADE, PASS, PAY_FINE, TAX_FLAT, TAX_PERCENT }

## 起始资金。破产制之下这就是"一根引线有多长"：给多了谁都破不了产。
##
## 这两个数字是量出来的，不是拍的：1500/200 的时候 4 个人要打 390 轮，
## 1000/150 是 195 轮，都在"没人愿意玩"的范围里。
const START_CASH := 600
## 绕一圈的补贴。**这是全局收入的主要来源**，所以它对一局时长的影响
## 比租金还大——收入盖过过路费，谁都破不了产。
const GO_BONUS := 100
const JAIL_FINE := 100
## 回合上限，0 表示不限。默认不限：结束靠破产，不靠轮数。
const DEFAULT_MAX_ROUNDS := 0
## 卡片连锁移动的深度上限。卡片里再抽卡片是可能的（前进 → 落到机会格），
## 不限一下会转不出来。
const MAX_CARD_CHAIN := 3

var _order: Array[int] = []
var _names: Array = []   ## [{peer_id, name}]，只用来写日志
var _cash := {}          ## peer -> 现金
var _pos := {}           ## peer -> 所在格
var _owner := {}         ## 格 -> peer
var _level := {}         ## 格 -> 等级（1 起）
var _skip := {}          ## peer -> 还要暂停几个回合
var _out := {}           ## peer -> true 表示已出局
var _turn_count := 0     ## 已经走了多少个回合（所有人加起来），只用来显示
var _max_rounds := DEFAULT_MAX_ROUNDS

var _cursor := 0
var _phase: Phase = Phase.AWAIT_ROLL
var _decision: Decision = Decision.NONE
var _pending_cell := -1
var _rng := RandomNumberGenerator.new()
var _chance: Array = []
var _fate: Array = []
var _notes: Array = []   ## 最近发生的事，界面直接拿去显示
var _last_dice: Array = []   ## 最近一次掷骰的点数，界面拿它画骰子
var _last_card := {}         ## 最近抽到的卡片，界面拿它放抽卡动画
var _card_seq := 0           ## 抽卡次数。界面靠它判断"又来了一张新的"


# ---------------------------------------------------------------- 开局

## players: [{peer_id, name}]；cfg: {rounds, start_cash}
## seed_value 为 0 时用真随机，非 0 时用它复现——测试靠这个重放。
func setup(players: Array, cfg: Dictionary = {}, seed_value := 0) -> void:
	_order.clear()
	_names.clear()
	_cash.clear()
	_pos.clear()
	_owner.clear()
	_level.clear()
	_skip.clear()
	_out.clear()
	_notes.clear()
	_last_dice.clear()
	_last_card = {}
	_card_seq = 0

	_max_rounds = maxi(0, int(cfg.get("max_rounds", DEFAULT_MAX_ROUNDS)))
	var start_cash := maxi(1, int(cfg.get("start_cash", START_CASH)))

	for entry in players:
		var peer := int(entry["peer_id"])
		_order.append(peer)
		_names.append({
			"peer_id": peer,
			"name": String(entry.get("name", "玩家%d" % peer)),
		})
		_cash[peer] = start_cash
		_pos[peer] = 0
	_turn_count = 0

	if seed_value == 0:
		_rng.randomize()
	else:
		_rng.seed = seed_value

	_chance = _shuffled(TourCards.deck_for(true))
	_fate = _shuffled(TourCards.deck_for(false))

	_cursor = 0
	_phase = Phase.AWAIT_ROLL
	_decision = Decision.NONE
	_pending_cell = -1


# ---------------------------------------------------------------- 查询

func players() -> Array[int]:
	return _order.duplicate()


func phase() -> Phase:
	return _phase


func is_finished() -> bool:
	return _phase == Phase.FINISHED


func current_player() -> int:
	if _order.is_empty() or _phase == Phase.FINISHED:
		return 0
	return _order[_cursor]


func decision() -> Decision:
	return _decision


## 正在等玩家做决定的那一格
func pending_cell() -> int:
	return _pending_cell


func cash_of(peer_id: int) -> int:
	return int(_cash.get(peer_id, 0))


func pos_of(peer_id: int) -> int:
	return int(_pos.get(peer_id, 0))


func owner_of(cell: int) -> int:
	return int(_owner.get(cell, 0))


func level_of(cell: int) -> int:
	return int(_level.get(cell, 0))


func skip_of(peer_id: int) -> int:
	return int(_skip.get(peer_id, 0))


func is_out(peer_id: int) -> bool:
	return _out.has(peer_id)


## 回合上限。0 表示不限——正常局不会走到这一步。
func max_rounds() -> int:
	return _max_rounds


## 当前是第几轮（从 1 起）。
##
## **除以开局人数，不是还活着的人数**：有人出局之后一圈确实变短了，但
## 玩家心里的"第几轮"是按开局那圈算的。按活人算的话，最后剩一个时
## 每走一步都算一轮，轮数会飙得莫名其妙（实测显示过 78 轮，实际才 15 轮）。
func round_index() -> int:
	return _turn_count / maxi(1, _order.size()) + 1


## 还没出局的人数
func alive_count() -> int:
	return _alive_count()


## 这个人手上这一组是不是集齐了。集齐 → 租金翻倍。
func has_monopoly(peer_id: int, group: int) -> bool:
	if group < 0:
		return false
	var cells := TourBoard.cells_in_group(group)
	if cells.is_empty():
		return false
	for cell in cells:
		if owner_of(cell) != peer_id:
			return false
	return true


## 这一格现在的过路费（含垄断翻倍）。没人拥有就是 0。
func rent_at(cell: int) -> int:
	var owner := owner_of(cell)
	if owner == 0:
		return 0
	return TourBoard.rent_of(cell, level_of(cell),
		has_monopoly(owner, TourBoard.group_of(cell)))


## 买下这一格要多少钱
func buy_price(cell: int) -> int:
	return TourBoard.price_of(cell)


## 升级这一格要多少钱（已经满级返回 0）
func upgrade_price(cell: int) -> int:
	return TourBoard.upgrade_cost(cell, level_of(cell))


## 总资产 = 现金 + 各地产的（地价 + 已投入的升级费）。
## 用投入成本而不是市价：不然"买满一色的地"会比"存现金"值钱太多，
## 玩家会发现刷资产的最优解是乱买。
func assets_of(peer_id: int) -> int:
	var total := cash_of(peer_id)
	for cell in _owner:
		if owner_of(int(cell)) != peer_id:
			continue
		total += TourBoard.price_of(int(cell))
		for lv in range(1, level_of(int(cell))):
			total += TourBoard.upgrade_cost(int(cell), lv)
	return maxi(0, total)


## 排名：资产从高到低。出局的人资产按 0 算，自然排在最后。
func ranking() -> Array:
	var rows: Array = []
	for peer in _order:
		rows.append({
			"peer_id": peer,
			"assets": assets_of(peer),
			"cash": cash_of(peer),
			"out": is_out(peer),
		})
	rows.sort_custom(func(a, b): return int(a["assets"]) > int(b["assets"]))
	return rows


func winner() -> int:
	var rows := ranking()
	if rows.is_empty():
		return 0
	return int(rows[0]["peer_id"])


## 最近发生的事，最新的在后面。界面直接拿去滚日志。
func notes() -> Array:
	return _notes.duplicate()


## 交给界面（以及以后的网络层）的状态字典。
##
## **界面只认这一份结构**，不直接读规则对象——单机时它由这里生成，联机时
## 由主机广播过来，牌桌那层就不用为两边各写一套。这条是 UNO 那边踩出来的
## 经验：等做完界面再抽这一层，改动会大得多。
func snapshot() -> Dictionary:
	var rows: Array = []
	for peer in _order:
		rows.append({
			"peer_id": peer,
			"name": _name_of(peer),
			"cash": cash_of(peer),
			"assets": assets_of(peer),
			"pos": pos_of(peer),
			"out": is_out(peer),
			"skip": skip_of(peer),
		})
	var owners := {}
	var levels := {}
	for cell in _owner:
		owners[int(cell)] = owner_of(int(cell))
		levels[int(cell)] = level_of(int(cell))
	return {
		"players": rows,
		"owner": owners,
		"level": levels,
		"current": current_player(),
		"phase": _phase,
		"decision": _decision,
		"pending_cell": _pending_cell,
		# 等玩家选税怎么交时，把两个选项的金额一起给出去，界面直接用
		"tax": tax_options(current_player()) if _decision == Decision.TAX else {},
		"round": round_index(),
		"max_rounds": _max_rounds,
		"alive": alive_count(),
		"finished": is_finished(),
		"log": last_note(),
		"notes": _notes.duplicate(),
		"dice": _last_dice.duplicate(),
		"card": _last_card.duplicate(),
		"card_seq": _card_seq,
	}


func last_note() -> String:
	if _notes.is_empty():
		return ""
	return String(_notes[-1])


# ---------------------------------------------------------------- 动作

## 掷骰并走。房主调用，点数由这里生成——防作弊。
func roll(peer_id: int) -> Dictionary:
	if _phase == Phase.FINISHED:
		return _err("这一局已经结束了")
	if _phase != Phase.AWAIT_ROLL:
		return _err("现在不能掷骰")
	if peer_id != current_player():
		return _err("还没轮到你")

	# 滞留：这回合先跳过
	if skip_of(peer_id) > 0:
		_skip[peer_id] = skip_of(peer_id) - 1
		_note("%s 在滞留区待了一回合" % _name_of(peer_id))
		_end_turn()
		return {"ok": true, "skipped": true}

	var dice := [_rng.randi_range(1, 6), _rng.randi_range(1, 6)]
	_last_dice = dice.duplicate()
	var steps := int(dice[0]) + int(dice[1])
	_move(peer_id, steps, true)
	_note("%s 掷出 %d 点，走到 %s" % [
		_name_of(peer_id), steps, TourBoard.name_of(pos_of(peer_id))])
	_settle(peer_id)
	# 落在不需要决定的地方（税、别人的地、卡片、休息区……）就在这里交棒。
	# 少了这一句整局会卡死：谁也不轮到，谁也不动——测试里那条「一步之后
	# 局面必须动过」的检测就是为它准备的。
	if _phase != Phase.DECIDING:
		_end_turn()
	return {"ok": true, "dice": dice, "steps": steps, "cell": pos_of(peer_id)}


## 买下当前这一格
func buy(peer_id: int) -> Dictionary:
	var guard := _guard_decision(peer_id, Decision.BUY)
	if not guard.is_empty():
		return guard
	var cell := _pending_cell
	var price := TourBoard.price_of(cell)
	_cash[peer_id] = cash_of(peer_id) - price
	_owner[cell] = peer_id
	_level[cell] = 1
	_note("%s 买下了 %s（%d）" % [_name_of(peer_id), TourBoard.name_of(cell), price])
	_end_turn()
	return {"ok": true, "cell": cell, "price": price}


## 升级当前这一格
func upgrade(peer_id: int) -> Dictionary:
	var guard := _guard_decision(peer_id, Decision.UPGRADE)
	if not guard.is_empty():
		return guard
	var cell := _pending_cell
	var cost := TourBoard.upgrade_cost(cell, level_of(cell))
	_cash[peer_id] = cash_of(peer_id) - cost
	_level[cell] = level_of(cell) + 1
	_note("%s 把 %s 升到 %d 级（%d）" % [
		_name_of(peer_id), TourBoard.name_of(cell), level_of(cell), cost])
	_end_turn()
	return {"ok": true, "cell": cell, "cost": cost, "level": level_of(cell)}


## 放弃这次机会（不买 / 不升级），直接结束回合。
##
## 名字不叫 pass：那是 GDScript 的保留字，会直接报「Expected function name」。
func decline(peer_id: int) -> Dictionary:
	if peer_id != current_player():
		return _err("还没轮到你")
	if _phase == Phase.DECIDING and _decision == Decision.BUY:
		_note("%s 没有买 %s" % [_name_of(peer_id),
			TourBoard.name_of(_pending_cell)])
	_end_turn()
	return {"ok": true}


## 交罚款立刻离开滞留区。只能在轮到自己的时候用。
func pay_fine(peer_id: int) -> Dictionary:
	if peer_id != current_player():
		return _err("还没轮到你")
	if skip_of(peer_id) <= 0:
		return _err("不在滞留区")
	if cash_of(peer_id) < JAIL_FINE:
		return _err("钱不够交罚款")
	_cash[peer_id] = cash_of(peer_id) - JAIL_FINE
	_skip[peer_id] = 0
	_note("%s 交了 %d 罚款离开滞留区" % [_name_of(peer_id), JAIL_FINE])
	return {"ok": true}


## 落在所得税上时的两个选项：交固定值，还是交总资产的一个比例。
##
## 返回 {flat, percent, by_percent, cheaper}。by_percent 按**总资产**
## （现金 + 地产成本）算，跟经典的「总资产 10%」一致。
func tax_options(peer_id: int, cell := -1) -> Dictionary:
	var target := _pending_cell if cell < 0 else cell
	var flat := TourBoard.amount_of(target)
	var percent := TourBoard.percent_of(target)
	var by_percent := 0
	if percent > 0:
		by_percent = maxi(1, roundi(float(assets_of(peer_id)) * float(percent) / 100.0))
	return {
		"flat": flat,
		"percent": percent,
		"by_percent": by_percent,
		"cheaper": "percent" if by_percent < flat else "flat",
	}


## 交固定值（所得税的选项之一）
func pay_tax_flat(peer_id: int) -> Dictionary:
	var guard := _guard_decision(peer_id, Decision.TAX)
	if not guard.is_empty():
		return guard
	var options := tax_options(peer_id)
	var amount := int(options["flat"])
	_note("%s 交了所得税 %d" % [_name_of(peer_id), amount])
	_pay(peer_id, amount)
	_end_turn()
	return {"ok": true, "amount": amount}


## 按总资产的比例交（所得税的另一个选项）
func pay_tax_percent(peer_id: int) -> Dictionary:
	var guard := _guard_decision(peer_id, Decision.TAX)
	if not guard.is_empty():
		return guard
	var options := tax_options(peer_id)
	var amount := int(options["by_percent"])
	_note("%s 按总资产的 %d%% 交了所得税 %d" % [
		_name_of(peer_id), int(options["percent"]), amount])
	_pay(peer_id, amount)
	_end_turn()
	return {"ok": true, "amount": amount}


## 按当前局面推荐一个动作。界面（超时兜底）和 AI 都用它。
func suggested_action(peer_id: int) -> Action:
	if peer_id != current_player():
		return Action.PASS
	if _phase == Phase.DECIDING:
		match _decision:
			Decision.BUY:
				return Action.BUY
			Decision.UPGRADE:
				return Action.UPGRADE
			Decision.TAX:
				# 哪个便宜交哪个
				var options := tax_options(peer_id)
				return Action.TAX_PERCENT if String(options["cheaper"]) == "percent" \
					else Action.TAX_FLAT
		return Action.PASS
	if skip_of(peer_id) > 0 and cash_of(peer_id) >= JAIL_FINE * 3:
		return Action.PAY_FINE
	return Action.ROLL


# ---------------------------------------------------------------- 内部

func _guard_decision(peer_id: int, want: Decision) -> Dictionary:
	if _phase == Phase.FINISHED:
		return _err("这一局已经结束了")
	if _phase != Phase.DECIDING:
		return _err("现在没有要决定的事")
	if peer_id != current_player():
		return _err("还没轮到你")
	if _decision != want:
		return _err("现在不能这么做")
	return {}


## 往前走（或退）。只有前进且绕回起点才给过路费。
func _move(peer_id: int, steps: int, forward: bool) -> void:
	var from := pos_of(peer_id)
	var to := posmod(from + steps, TourBoard.size())
	if forward and to < from:
		_cash[peer_id] = cash_of(peer_id) + GO_BONUS
		_note("%s 经过出发，收 %d" % [_name_of(peer_id), GO_BONUS])
	_pos[peer_id] = to


## 落地结算。抽到卡片又移动时会递归回来，用 chain 限制深度。
func _settle(peer_id: int, chain := 0) -> void:
	if is_out(peer_id):
		return
	var cell := pos_of(peer_id)
	match TourBoard.kind_of(cell):
		TourBoard.Kind.CITY, TourBoard.Kind.STATION, TourBoard.Kind.UTILITY:
			_settle_property(peer_id, cell)
		TourBoard.Kind.TAX:
			# 所得税给两个选项（交固定值 / 交总资产的比例），奢侈税只有固定值
			if TourBoard.has_tax_choice(cell):
				_decision = Decision.TAX
				_pending_cell = cell
				_phase = Phase.DECIDING
			else:
				var amount := TourBoard.amount_of(cell)
				_note("%s 交了 %s %d" % [
					_name_of(peer_id), TourBoard.name_of(cell), amount])
				_pay(peer_id, amount)
		TourBoard.Kind.CHANCE:
			_draw_card(peer_id, true, chain)
		TourBoard.Kind.FATE:
			_draw_card(peer_id, false, chain)
		TourBoard.Kind.TO_JAIL:
			_pos[peer_id] = TourBoard.JAIL_CELL
			_skip[peer_id] = 1
			_note("%s 被送进滞留区" % _name_of(peer_id))


func _settle_property(peer_id: int, cell: int) -> void:
	var owner := owner_of(cell)
	if owner == 0:
		# 钱不够买就不给选项，省一次无意义的点击
		if cash_of(peer_id) >= TourBoard.price_of(cell):
			_decision = Decision.BUY
			_pending_cell = cell
			_phase = Phase.DECIDING
		return

	if owner == peer_id:
		if level_of(cell) < TourBoard.max_level(cell) \
				and cash_of(peer_id) >= upgrade_price(cell):
			_decision = Decision.UPGRADE
			_pending_cell = cell
			_phase = Phase.DECIDING
		return

	var rent := rent_at(cell)
	_note("%s 走到 %s，付过路费 %d 给 %s" % [
		_name_of(peer_id), TourBoard.name_of(cell), rent, _name_of(owner)])
	var paid := _pay(peer_id, rent)
	# 出局的人不再收钱：他的地已经释放了
	if paid and not is_out(owner):
		_cash[owner] = cash_of(owner) + rent


## 扣钱。扣到负数就出局。返回是否顺利付清。
func _pay(peer_id: int, amount: int) -> bool:
	if amount <= 0:
		return true
	_cash[peer_id] = cash_of(peer_id) - amount
	if cash_of(peer_id) < 0:
		_knock_out(peer_id)
		return false
	return true


## 出局：现金清 0，名下的地全部释放（别人以后可以买）。
##
## 不做"变卖地产抵债"：那需要一整套负债状态机，手机上操作也繁琐，
## 而聚会场景没人愿意等一个人算账。
func _knock_out(peer_id: int) -> void:
	_out[peer_id] = true
	_cash[peer_id] = 0
	var released := PackedStringArray()
	for cell in _owner.keys():
		if owner_of(int(cell)) == peer_id:
			released.append(TourBoard.name_of(int(cell)))
			_owner.erase(cell)
			_level.erase(cell)
	_skip.erase(peer_id)
	_note("%s 付不出钱，出局了%s" % [_name_of(peer_id),
		"" if released.is_empty() else "（%s 重新开放）" % "、".join(released)])
	# 立刻被打结算打断的话，把待决定的事收掉
	if _phase == Phase.DECIDING:
		_decision = Decision.NONE
		_pending_cell = -1


func _draw_card(peer_id: int, is_chance: bool, chain: int) -> void:
	var deck: Array = _chance if is_chance else _fate
	if deck.is_empty():
		return
	var card: Dictionary = deck.pop_front()
	deck.append(card)          # 抽完放回队尾，循环使用
	_note("%s 抽到：%s" % [_name_of(peer_id), String(card["text"])])
	_last_card = {"text": String(card["text"]), "chance": is_chance}
	_card_seq += 1
	if is_out(peer_id):
		return

	match int(card["effect"]):
		TourCards.Effect.GAIN:
			_cash[peer_id] = cash_of(peer_id) + int(card["value"])
		TourCards.Effect.PAY:
			_pay(peer_id, int(card["value"]))
		TourCards.Effect.SKIP:
			_skip[peer_id] = skip_of(peer_id) + int(card["value"])
		TourCards.Effect.TO_JAIL:
			_pos[peer_id] = TourBoard.JAIL_CELL
			_skip[peer_id] = 1
		TourCards.Effect.MOVE:
			if chain >= MAX_CARD_CHAIN:
				return
			var steps := int(card["value"])
			_move(peer_id, steps, steps > 0)
			_settle(peer_id, chain + 1)


## 交棒。扣掉这个人的一个回合，走到下一个还有回合可走的人。
func _end_turn() -> void:
	_turn_count += 1
	_decision = Decision.NONE
	_pending_cell = -1
	_phase = Phase.AWAIT_ROLL

	# 结束条件：只剩一个人没破产。回合上限只是保险丝，正常局走不到。
	if _alive_count() <= 1 or _over_max_rounds():
		_phase = Phase.FINISHED
		return
	_advance_cursor()


func _advance_cursor() -> void:
	if _order.is_empty():
		return
	for step in _order.size():
		_cursor = posmod(_cursor + 1, _order.size())
		if not is_out(_order[_cursor]):
			return


func _over_max_rounds() -> bool:
	return _max_rounds > 0 and round_index() > _max_rounds


func _alive_count() -> int:
	var n := 0
	for peer in _order:
		if not is_out(peer):
			n += 1
	return n


func _shuffled(cards: Array) -> Array:
	var out := cards.duplicate(true)
	# 用同一个 rng 洗牌：给定种子，牌序也是可复现的
	for i in range(out.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp: Variant = out[i]
		out[i] = out[j]
		out[j] = tmp
	return out


func _name_of(peer_id: int) -> String:
	for entry in _names:
		if int(entry["peer_id"]) == peer_id:
			return String(entry["name"])
	return "玩家%d" % peer_id


func _note(text: String) -> void:
	_notes.append(text)
	if _notes.size() > 60:
		_notes.pop_front()


func _err(message: String) -> Dictionary:
	return {"ok": false, "error": message}
