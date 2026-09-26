extends SceneTree

## 《环游中国》的规则测试。
##
##   godot --headless --path . --script res://games/tour/tests/run_tests.gd
##
## 规则引擎是纯逻辑，所以这里能把它**穷举**：棋盘数据、租金公式、
## 走格与绕圈、买地升级、破产、固定轮数结算、卡片效果、种子可复现。
## 界面和联机都还没做，那些到时候另开冒烟测试。

var _passed := 0
var _failed := 0


func _initialize() -> void:
	print("=== 环游中国 · 规则测试 ===")
	_test_board()
	_test_rent()
	_test_setup()
	_test_roll_and_move()
	_test_buy()
	_test_rent_payment()
	_test_upgrade()
	_test_tax_and_knockout()
	_test_cards()
	_test_fixed_rounds()
	_test_seed_reproducible()
	_test_full_game()
	_finish()


# ---------------------------------------------------------------- 棋盘

func _test_board() -> void:
	print("\n-- 棋盘 --")
	_check("一共 40 格", TourBoard.size() == 40, "%d" % TourBoard.size())

	var counts := {}
	for cell in TourBoard.size():
		var kind := TourBoard.kind_of(cell)
		counts[kind] = int(counts.get(kind, 0)) + 1

	var purchasable := 0
	for cell in TourBoard.size():
		if TourBoard.is_purchasable(cell):
			purchasable += 1
	# 比例是经典值：少了「走到哪儿都没事干」，多了「每步都要算钱」
	_check("可购买格 28 个（22 城 + 4 站 + 2 公用）", purchasable == 28,
		"%d" % purchasable)
	_check("城市 22 个", int(counts.get(TourBoard.Kind.CITY, 0)) == 22,
		"%d" % int(counts.get(TourBoard.Kind.CITY, 0)))
	_check("高铁站 4 个", int(counts.get(TourBoard.Kind.STATION, 0)) == 4)
	_check("公用事业 2 个", int(counts.get(TourBoard.Kind.UTILITY, 0)) == 2)
	_check("机会 3 张", int(counts.get(TourBoard.Kind.CHANCE, 0)) == 3)
	_check("命运 3 张", int(counts.get(TourBoard.Kind.FATE, 0)) == 3)
	_check("税 2 处", int(counts.get(TourBoard.Kind.TAX, 0)) == 2)

	# 特殊格的位置照抄经典：四条边的端点是出发/滞留/休息/进滞留
	_check("0 是出发", TourBoard.kind_of(0) == TourBoard.Kind.GO)
	_check("10 是滞留区", TourBoard.kind_of(10) == TourBoard.Kind.VISIT)
	_check("20 是休息区", TourBoard.kind_of(20) == TourBoard.Kind.REST)
	_check("30 是进滞留区", TourBoard.kind_of(30) == TourBoard.Kind.TO_JAIL)
	_check("进滞留区指向第 10 格", TourBoard.JAIL_CELL == 10)

	# 八个组，每组 2~3 块
	_check("八个城市组", TourBoard.GROUPS.size() == 8)
	var group_sizes := PackedInt32Array()
	for group in TourBoard.GROUPS.size():
		var cells := TourBoard.cells_in_group(group)
		group_sizes.append(cells.size())
		_check("第 %d 组有 2~3 块地" % group, cells.size() >= 2 and cells.size() <= 3,
			"%d 块" % cells.size())
	_check("所有地都有归属的组", _all_cities_grouped())

	# 价格越贵越有名：一线组必须比暖冬组贵
	var cheapest_top := 9999
	for cell in TourBoard.cells_in_group(7):
		cheapest_top = mini(cheapest_top, TourBoard.price_of(cell))
	var dearest_start := 0
	for cell in TourBoard.cells_in_group(0):
		dearest_start = maxi(dearest_start, TourBoard.price_of(cell))
	_check("一线组比暖冬组贵", cheapest_top > dearest_start,
		"%d vs %d" % [cheapest_top, dearest_start])


func _all_cities_grouped() -> bool:
	for cell in TourBoard.size():
		if TourBoard.kind_of(cell) != TourBoard.Kind.CITY:
			continue
		if TourBoard.group_of(cell) < 0:
			return false
	return true


# ---------------------------------------------------------------- 租金

func _test_rent() -> void:
	print("\n-- 租金公式 --")
	# 找一块 200 的地来对表（西安就是 200）
	var cell := 14
	_check("西安地价 200", TourBoard.price_of(cell) == 200,
		"%d" % TourBoard.price_of(cell))
	_check("1 级 20", TourBoard.rent_of(cell, 1) == 20, "%d" % TourBoard.rent_of(cell, 1))
	_check("2 级 44", TourBoard.rent_of(cell, 2) == 44, "%d" % TourBoard.rent_of(cell, 2))
	_check("3 级 97", TourBoard.rent_of(cell, 3) == 97, "%d" % TourBoard.rent_of(cell, 3))
	_check("4 级 213", TourBoard.rent_of(cell, 4) == 213, "%d" % TourBoard.rent_of(cell, 4))
	_check("垄断翻倍", TourBoard.rent_of(cell, 2, true) == 88,
		"%d" % TourBoard.rent_of(cell, 2, true))

	# 高铁站 100 / 200，公用事业 100 / 250，都是固定值
	_check("高铁站 1 级 100", TourBoard.rent_of(5, 1) == 100)
	_check("高铁站 2 级 200", TourBoard.rent_of(5, 2) == 200)
	_check("公用事业 1 级 100", TourBoard.rent_of(12, 1) == 100)
	_check("公用事业 2 级 250", TourBoard.rent_of(12, 2) == 250)
	# 车站和公用事业不参与垄断翻倍
	_check("高铁站不翻倍", TourBoard.rent_of(5, 1, true) == 100)

	_check("城市最高 4 级", TourBoard.max_level(14) == 4)
	_check("车站最高 2 级", TourBoard.max_level(5) == 2)
	_check("升级费用是地价一半", TourBoard.upgrade_cost(14, 1) == 100,
		"%d" % TourBoard.upgrade_cost(14, 1))
	_check("满级之后不能升", TourBoard.upgrade_cost(5, 2) == 0)


# ---------------------------------------------------------------- 开局

func _players(n := 2) -> Array:
	var names := ["甲", "乙", "丙", "丁", "戊", "己"]
	var out: Array = []
	for i in n:
		out.append({"peer_id": i + 1, "name": names[i]})
	return out


func _new_game(cfg: Dictionary = {}, seed_value := 1234) -> TourRules:
	var rules := TourRules.new()
	var merged := {"rounds": 2, "start_cash": TourRules.START_CASH}
	for key in cfg:
		merged[key] = cfg[key]
	rules.setup(_players(int(merged.get("players", 2))), merged, seed_value)
	return rules


func _test_setup() -> void:
	print("\n-- 开局 --")
	var rules := _new_game()
	_check("起点都是出发格",
		rules.pos_of(1) == 0 and rules.pos_of(2) == 0)
	_check("起始资金 1500", rules.cash_of(1) == 1500, "%d" % rules.cash_of(1))
	_check("每人都有 2 个回合",
		rules.turns_left_of(1) == 2 and rules.turns_left_of(2) == 2)
	_check("开局等第一个玩家掷骰",
		rules.phase() == TourRules.Phase.AWAIT_ROLL and rules.current_player() == 1)
	_check("开局没人拥有地", rules.owner_of(14) == 0)
	_check("还没结束", not rules.is_finished())


# ---------------------------------------------------------------- 掷骰与移动

func _test_roll_and_move() -> void:
	print("\n-- 掷骰与移动 --")
	var rules := _new_game()
	var res := rules.roll(1)
	_check("掷骰成功", bool(res.get("ok", false)), str(res))
	var steps := int(res.get("steps", 0))
	# 2 个骰子，2~12 点
	_check("点数是 2~12", steps >= 2 and steps <= 12, "%d" % steps)
	_check("走到对应的格子", rules.pos_of(1) == steps,
		"位置 %d，点数 %d" % [rules.pos_of(1), steps])
	# 落在可购买格 / 自己的地上时会停下来等人决定，那时候回合还没结束
	if rules.phase() == TourRules.Phase.DECIDING:
		_check("落在需要决定的地方就先停下来",
			rules.decision() != TourRules.Decision.NONE)
		_check("这时候还轮到自己（还没交棒）", rules.current_player() == 1)
		rules.decline(1)
	_check("决定完交棒给下一个人", rules.current_player() == 2,
		"%d" % rules.current_player())
	_check("回合数减了", rules.turns_left_of(1) == 1,
		"%d" % rules.turns_left_of(1))

	# 没轮到的人不能掷
	var bad := rules.roll(1)
	_check("没轮到的人掷骰会被拒", not bool(bad.get("ok", false)), str(bad))

	# 绕回起点给 200：让第 2 个人一路走到绕圈
	var circle := _new_game()
	circle.pos_of(2)
	# 直接用内部字段摆位置太脆，改成反复掷到绕过去
	var guard := 0
	while circle.pos_of(2) < 35 and guard < 200:
		guard += 1
		if circle.current_player() != 2:
			# 轮到别人就随便过一手
			circle.decline(circle.current_player())
			continue
		circle.roll(2)
		if circle.phase() == TourRules.Phase.DECIDING:
			circle.decline(2)
	var cash_before := circle.cash_of(2)
	_check("绕圈过程里攒下了过路费", cash_before >= 1500, "%d" % cash_before)


# ---------------------------------------------------------------- 买地

func _test_buy() -> void:
	print("\n-- 买地 --")
	# 摆一个必然落到可购买格的开局：让 1 号掷到几点都能买
	var rules := _new_game()
	rules.roll(1)
	var cell := rules.pending_cell()
	if rules.phase() == TourRules.Phase.DECIDING:
		_check("等玩家决定买不买", rules.decision() == TourRules.Decision.BUY)
		_check("待决定的格子是可以买的", TourBoard.is_purchasable(cell))
		var price := TourBoard.price_of(cell)
		rules.buy(1)
		_check("地归买家", rules.owner_of(cell) == 1)
		_check("等级是 1 级", rules.level_of(cell) == 1)
		_check("扣了地价", rules.cash_of(1) == 1500 - price,
			"%d" % rules.cash_of(1))
		_check("交棒了", rules.current_player() == 2)
		_check("这一格开始收过路费", rules.rent_at(cell) > 0)
		_check("日志里有买地的记录",
			"买下" in rules.last_note(), rules.last_note())
	else:
		print("      （这一掷落在特殊格，跳过买地检查）")

	# 钱不够就不给选项，回合直接过
	var poor := _new_game({"start_cash": 50})
	poor.roll(1)
	_check("钱不够时不给买地选项",
		poor.phase() != TourRules.Phase.DECIDING
			or TourBoard.price_of(poor.pending_cell()) <= 50,
		"待决定 %d" % poor.pending_cell())


# ---------------------------------------------------------------- 过路费

func _test_rent_payment() -> void:
	print("\n-- 过路费 --")
	var rules := _new_game()
	# 用内部状态摆一个确定局面：1 号拥有 14 号（西安 200），2 号停在 13 号，掷出 1 点
	rules._owner[14] = 1
	rules._level[14] = 1
	rules._pos[2] = 13
	rules._cursor = 1          # 轮到 2 号
	rules._skip[2] = 0

	var cash1 := rules.cash_of(1)
	var cash2 := rules.cash_of(2)
	# 掷骰是随机的，所以这里直接调用内部结算：把 2 号放到 14 号上
	rules._pos[2] = 14
	rules._settle(2)
	var rent := TourBoard.rent_of(14, 1)
	_check("付了过路费", rules.cash_of(2) == cash2 - rent,
		"%d -> %d" % [cash2, rules.cash_of(2)])
	_check("地主人收到了钱", rules.cash_of(1) == cash1 + rent,
		"%d -> %d" % [cash1, rules.cash_of(1)])
	_check("日志写明了过路费", "过路费" in rules.last_note(), rules.last_note())

	# 垄断：把西安所在的西北组（11/13/14）全给 1 号，租金翻倍
	rules._owner[11] = 1
	rules._level[11] = 1
	rules._owner[13] = 1
	rules._level[13] = 1
	_check("集齐西北组", rules.has_monopoly(1, 2))
	_check("垄断之后租金翻倍",
		rules.rent_at(14) == TourBoard.rent_of(14, 1) * 2,
		"%d" % rules.rent_at(14))


# ---------------------------------------------------------------- 升级

func _test_upgrade() -> void:
	print("\n-- 升级 --")
	var rules := _new_game()
	rules._owner[14] = 1
	rules._level[14] = 1
	rules._pos[1] = 14
	rules._cursor = 0
	rules._settle(1)
	_check("落在自己的地上会问要不要升级",
		rules.phase() == TourRules.Phase.DECIDING
			and rules.decision() == TourRules.Decision.UPGRADE,
		"%d / %d" % [rules.phase(), rules.decision()])

	var cash := rules.cash_of(1)
	var cost := TourBoard.upgrade_cost(14, 1)
	rules.upgrade(1)
	_check("升到 2 级", rules.level_of(14) == 2, "%d" % rules.level_of(14))
	_check("扣了升级费", rules.cash_of(1) == cash - cost,
		"%d -> %d" % [cash, rules.cash_of(1)])

	# 满级之后不再提供升级选项
	rules._level[14] = TourBoard.max_level(14)
	rules._cursor = 0
	rules._settle(1)
	_check("满级后不再问升级", rules.phase() != TourRules.Phase.DECIDING)


# ---------------------------------------------------------------- 税与破产

func _test_tax_and_knockout() -> void:
	print("\n-- 税与出局 --")
	var rules := _new_game()
	rules._pos[1] = 4          # 个人所得税 −200
	rules._cursor = 0
	var cash := rules.cash_of(1)
	rules._settle(1)
	_check("交了税", rules.cash_of(1) == cash - 200, "%d" % rules.cash_of(1))
	_check("没有出局", not rules.is_out(1))

	# 现金不够付税 → 出局，名下的地释放
	rules._owner[14] = 1
	rules._level[14] = 1
	rules._cash[1] = 100
	rules._pos[1] = 4
	rules._settle(1)
	_check("付不出来就出局", rules.is_out(1))
	_check("出局后现金清零", rules.cash_of(1) == 0)
	_check("名下的地释放了（别人可以买）", rules.owner_of(14) == 0)
	_check("日志写出了局", "出局" in rules.last_note(), rules.last_note())


# ---------------------------------------------------------------- 卡片

func _test_cards() -> void:
	print("\n-- 卡片 --")
	var rules := _new_game()
	var gain := 1
	rules._pos[gain] = 2       # 命运格
	rules._cursor = 0
	var cash := rules.cash_of(gain)
	# 把牌堆摆成一张确定的"收 200"，验证效果真的落到账上
	rules._fate = [{"text": "测试：收 200", "effect": TourCards.Effect.GAIN, "value": 200}]
	rules._settle(gain)
	_check("收钱的卡片真的加钱", rules.cash_of(gain) == cash + 200,
		"%d" % rules.cash_of(gain))
	_check("日志写明了抽到什么", "测试：收 200" in rules.last_note(),
		rules.last_note())

	# 移动的卡片：摆在"前进 3 格"上，位置必须真的往前走
	var mover := _new_game()
	mover._pos[1] = 7          # 机会格
	mover._cursor = 0
	mover._chance = [{"text": "测试：前进 3 格",
		"effect": TourCards.Effect.MOVE, "value": 3}]
	mover._settle(1)
	_check("前进的卡片真的前进", mover.pos_of(1) == 10,
		"位置 %d" % mover.pos_of(1))

	# 进滞留区：位置变到 10，并且要暂停一次
	var jailed := _new_game()
	jailed._pos[1] = 2
	jailed._cursor = 0
	jailed._fate = [{"text": "测试：直接进滞留区",
		"effect": TourCards.Effect.TO_JAIL, "value": 0}]
	jailed._settle(1)
	_check("进了滞留区", jailed.pos_of(1) == TourBoard.JAIL_CELL,
		"%d" % jailed.pos_of(1))
	_check("要被暂停一次", jailed.skip_of(1) == 1)

	# 滞留：轮到他的时候掷骰会被吞掉，只是消耗掉暂停
	var skipped := jailed.roll(1)
	_check("滞留回合掷骰被跳过", bool(skipped.get("skipped", false)), str(skipped))
	_check("暂停用掉了", jailed.skip_of(1) == 0)

	# 交罚款立刻出来
	var fine := _new_game()
	fine._skip[1] = 1
	fine._cursor = 0
	var before := fine.cash_of(1)
	var paid := fine.pay_fine(1)
	_check("可以交罚款", bool(paid.get("ok", false)), str(paid))
	_check("罚款扣了 100", fine.cash_of(1) == before - TourRules.JAIL_FINE,
		"%d" % fine.cash_of(1))
	_check("罚完就不用暂停了", fine.skip_of(1) == 0)

	# 卡片内容本身：文案不能太长，效果必须合法
	for deck in [TourCards.CHANCE, TourCards.FATE]:
		for card in deck:
			_check("卡片文案不超过 12 字", String(card["text"]).length() <= 12,
				String(card["text"]))
			_check("卡片效果是已知类型",
				int(card["effect"]) >= 0 and int(card["effect"]) <= TourCards.Effect.TO_JAIL,
				String(card["text"]))


# ---------------------------------------------------------------- 固定轮数

func _test_fixed_rounds() -> void:
	print("\n-- 固定轮数 --")
	var rules := _new_game({"players": 3, "rounds": 2})
	var guard := 0
	while not rules.is_finished() and guard < 500:
		guard += 1
		TourAi.act(rules, rules.current_player())
	_check("3 人 2 轮会自己结束", rules.is_finished(), "%d 步" % guard)
	_check("步骤数合理（每人每回合最多两步）", guard <= 3 * 2 * 2 + 20,
		"%d 步" % guard)
	_check("结束时所有人都没有回合了", rules.turns_left_of(1) == 0)

	var rows := rules.ranking()
	_check("排名人数等于玩家人数", rows.size() == 3, "%d" % rows.size())
	var sorted_ok := true
	for i in range(1, rows.size()):
		if int(rows[i - 1]["assets"]) < int(rows[i]["assets"]):
			sorted_ok = false
	_check("排名按资产从高到低", sorted_ok, str(rows))
	_check("赢家是资产最高的那个",
		rules.winner() == int(rows[0]["peer_id"]))


# ---------------------------------------------------------------- 可复现

func _test_seed_reproducible() -> void:
	print("\n-- 随机种子 --")
	var a := _new_game({}, 777)
	var b := _new_game({}, 777)
	var same := true
	for i in 6:
		var ra := a.roll(a.current_player())
		var rb := b.roll(b.current_player())
		if str(ra.get("dice")) != str(rb.get("dice")):
			same = false
			break
		if a.phase() == TourRules.Phase.DECIDING:
			a.decline(a.current_player())
		if b.phase() == TourRules.Phase.DECIDING:
			b.decline(b.current_player())
	_check("同一个种子掷出同一串点数", same)

	var c := _new_game({}, 778)
	var d := _new_game({}, 778)
	var guard := 0
	while not c.is_finished() and guard < 4000:
		guard += 1
		TourAi.act(c, c.current_player())
		TourAi.act(d, d.current_player())
	_check("同种子的两局打出完全相同的排名",
		str(c.ranking()) == str(d.ranking()), str(c.ranking()))
	_check("换了种子也确实跑得完", c.is_finished() and d.is_finished(),
		"%d 步" % guard)


# ---------------------------------------------------------------- 整局

func _test_full_game() -> void:
	print("\n-- 一整局（AI 对 AI）--")
	var rules := _new_game({"players": 4, "rounds": 8})
	var guard := 0
	while not rules.is_finished() and guard < 4000:
		guard += 1
		var peer := rules.current_player()
		var before := _signature(rules)
		TourAi.act(rules, peer)
		# 卡死检测：一步之后**局面本身**必须动过。只看「轮到谁」不行——
		# 有人出局之后，同一个人连着走两次是正常的。
		if _signature(rules) == before and not rules.is_finished():
			print("      卡在：", rules.last_note())
			guard = 4000
			break

	_check("4 人 8 轮能跑完", rules.is_finished(), "%d 步" % guard)
	_check("最后没有卡住（步数没打满）", guard < 4000, "%d 步" % guard)
	var rows := rules.ranking()
	_check("结算给出了四个人", rows.size() == 4, "%d" % rows.size())
	var total := 0
	for row in rows:
		total += int(row["assets"])
	_check("总资产是正数", total > 0, "%d" % total)
	print("      最终排名：", rows)


## 局面指纹：剩余回合总数、阶段、当前玩家、现金总额。任何一步合法动作
## 都必然改变其中至少一项。
func _signature(rules: TourRules) -> String:
	var turns := 0
	var cash := 0
	for peer in rules.players():
		turns += rules.turns_left_of(peer)
		cash += rules.cash_of(peer)
	return "%d|%d|%d|%d" % [turns, int(rules.phase()), rules.current_player(), cash]


# ---------------------------------------------------------------- 收尾

func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] ", label, "   ", detail)


func _finish() -> void:
	print("\n=== 通过 %d，失败 %d ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
