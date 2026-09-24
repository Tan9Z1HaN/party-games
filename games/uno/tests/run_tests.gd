extends SceneTree

## UNO 规则引擎测试。纯逻辑，跑得飞快。
##
##   godot --headless --path . --script res://games/uno/tests/run_tests.gd

const P1 := 11
const P2 := 22
const P3 := 33

const RED := UnoDeck.C.RED
const YELLOW := UnoDeck.C.YELLOW
const GREEN := UnoDeck.C.GREEN
const BLUE := UnoDeck.C.BLUE
const WILD := UnoDeck.C.WILD

const SKIP := UnoDeck.F.SKIP
const REVERSE := UnoDeck.F.REVERSE
const DRAW2 := UnoDeck.F.DRAW2
const WILD_FACE := UnoDeck.F.WILD
const WILD4 := UnoDeck.F.WILD4

var _passed := 0
var _failed := 0

## 垫底牌。每个想「打一张牌然后继续」的场景都得让手牌不止一张，
## 否则那一张打完就直接赢了，后面的回合断言全落空。
var _filler := 0


func _initialize() -> void:
	print("=== UNO 规则测试 ===")
	_filler = UnoDeck.make(GREEN, UnoDeck.F.N9)
	_test_deck()
	_test_encoding()
	_test_deal()
	_test_play_validation()
	_test_effects()
	_test_stacking()
	_test_draw_rules()
	_test_uno_calls()
	_test_scoring()
	_test_pile_recycle()
	_test_determinism()
	_finish()


# ---------------------------------------------------------------- 工具

func _card(color: int, face: int) -> int:
	return UnoDeck.make(color, face)


## 把局面摆成指定样子。直接改内部字段——引擎是纯逻辑，
## 为了测试在生产代码里开专用接口，反而会让它背上包袱。
func _rig(rules: UnoRules, hands: Dictionary, top: int, active_color: int,
		current_peer: int, pile: Array = []) -> void:
	var typed := {}
	for key in hands:
		var arr: Array[int] = []
		arr.assign(hands[key])
		typed[key] = arr
	rules._hands = typed
	rules._discard = [top] as Array[int]
	rules._active_color = active_color
	var rest: Array[int] = []
	rest.assign(pile)
	rules._draw_pile = rest
	rules._cursor = rules._order.find(current_peer)
	rules._direction = 1
	rules._phase = UnoRules.Phase.PLAYING
	rules._pending_draw = 0
	rules._pending_face = -1
	rules._pending_play = -1
	rules._drawn_this_turn = false
	rules._uno_flag.clear()
	rules._color_chooser = 0
	rules._winner = 0


func _new_rules(cfg: Dictionary = {}, seed_value := 20260924) -> UnoRules:
	var rules := UnoRules.new()
	rules.setup([
		{"peer_id": P1}, {"peer_id": P2}, {"peer_id": P3},
	], cfg, seed_value)
	return rules


# ---------------------------------------------------------------- 牌组

func _test_deck() -> void:
	print("\n-- 牌组构成 --")
	var cards := UnoDeck.build()
	_check("共 108 张", cards.size() == 108, "%d" % cards.size())

	var counts := {}
	for card in cards:
		counts[card] = int(counts.get(card, 0)) + 1

	_check("变色 4 张", int(counts.get(_card(WILD, WILD_FACE), 0)) == 4)
	_check("变色+4 4 张", int(counts.get(_card(WILD, WILD4), 0)) == 4)
	for color in [RED, YELLOW, GREEN, BLUE]:
		var total := 0
		for card in cards:
			if UnoDeck.color_of(card) == color:
				total += 1
		_check("每色 25 张（%d）" % color, total == 25, "%d" % total)
		_check("每色 0 只有一张（%d）" % color,
			int(counts.get(_card(color, UnoDeck.F.N0), 0)) == 1)
		_check("每色 5 有两张（%d）" % color,
			int(counts.get(_card(color, UnoDeck.F.N5), 0)) == 2)
		_check("每色跳过两张（%d）" % color,
			int(counts.get(_card(color, SKIP), 0)) == 2)
		_check("每色 +2 两张（%d）" % color,
			int(counts.get(_card(color, DRAW2), 0)) == 2)


func _test_encoding() -> void:
	print("\n-- 牌面编码 --")
	for color in [RED, YELLOW, GREEN, BLUE, WILD]:
		for face in range(UnoDeck.F.WILD4 + 1):
			var card := _card(color, face)
			if UnoDeck.color_of(card) != color or UnoDeck.face_of(card) != face:
				_check("编码往返 %d/%d" % [color, face], false, "%d" % card)
				return
	_check("所有颜色/面值都能往返", true)
	_check("一个字节装得下", _card(WILD, WILD4) <= 255, "%d" % _card(WILD, WILD4))
	_check("万能牌判定", UnoDeck.is_wild(_card(WILD, WILD_FACE))
		and UnoDeck.is_wild(_card(WILD, WILD4)) and not UnoDeck.is_wild(_card(RED, SKIP)))
	_check("数字牌判定", UnoDeck.is_number(_card(RED, UnoDeck.F.N9))
		and not UnoDeck.is_number(_card(RED, SKIP)))


func _test_deal() -> void:
	print("\n-- 发牌 --")
	var rules := _new_rules()
	_check("每人 7 张", rules.hand_count(P1) == 7 and rules.hand_count(P2) == 7
		and rules.hand_count(P3) == 7)
	_check("弃牌堆有起始牌", rules.top_card() >= 0)
	_check("起始牌不是 +4", UnoDeck.face_of(rules.top_card()) != WILD4,
		UnoDeck.describe(rules.top_card()))
	_check("剩 108-21-1 张在牌堆", rules.draw_pile_size() == 108 - 21 - 1,
		"%d" % rules.draw_pile_size())
	_check("起始颜色跟着起始牌",
		rules.phase() == UnoRules.Phase.CHOOSING_COLOR
			or rules.active_color() == UnoDeck.color_of(rules.top_card()),
		"active=%d top=%s" % [rules.active_color(), UnoDeck.describe(rules.top_card())])


# ---------------------------------------------------------------- 合法性

func _test_play_validation() -> void:
	print("\n-- 出牌合法性 --")
	var rules := _new_rules()
	_rig(rules, {
		P1: [_card(RED, UnoDeck.F.N5), _card(BLUE, UnoDeck.F.N7), _card(WILD, WILD_FACE),
			_card(GREEN, UnoDeck.F.N9)],
		P2: [_card(RED, UnoDeck.F.N1)],
		P3: [_card(RED, UnoDeck.F.N2)],
	}, _card(RED, UnoDeck.F.N3), RED, P1)

	_check("同色可出", rules.can_play(P1, _card(RED, UnoDeck.F.N5)))
	_check("异色异数不可出", not rules.can_play(P1, _card(BLUE, UnoDeck.F.N7)))
	_check("万能牌随时可出", rules.can_play(P1, _card(WILD, WILD_FACE)))
	_check("手牌里没有的牌不能出", not rules.can_play(P1, _card(RED, UnoDeck.F.N9)))
	_check("不是自己回合不能出", not rules.can_play(P2, _card(RED, UnoDeck.F.N1)))

	# 同数字也能出
	_rig(rules, {
		P1: [_card(GREEN, UnoDeck.F.N3)], P2: [], P3: [],
	}, _card(RED, UnoDeck.F.N3), RED, P1)
	_check("同数字可出", rules.can_play(P1, _card(GREEN, UnoDeck.F.N3)))

	# 万能牌指定过的颜色要生效
	_rig(rules, {
		P1: [_card(BLUE, UnoDeck.F.N9)], P2: [], P3: [],
	}, _card(RED, UnoDeck.F.N3), BLUE, P1)
	_check("按指定颜色判定", rules.can_play(P1, _card(BLUE, UnoDeck.F.N9)))

	# 出牌失败要返回错误而不是崩
	var res := rules.draw_card(P2)
	_check("不是自己回合摸牌会被拒", not res.get("ok", false), str(res))


# ---------------------------------------------------------------- 效果

func _test_effects() -> void:
	print("\n-- 功能牌效果 --")

	# 跳过：P1 出跳过，应该轮到 P3
	var rules := _new_rules()
	_rig(rules, {
		P1: [_card(RED, SKIP), _filler],
		P2: [_card(RED, UnoDeck.F.N1)], P3: [_card(RED, UnoDeck.F.N2)],
	}, _card(RED, UnoDeck.F.N5), RED, P1)
	rules.play_card(P1, _card(RED, SKIP))
	_check("跳过下家", rules.current_player() == P3, "%d" % rules.current_player())

	# 反转：三人局里方向翻过来，下家变成 P3
	rules = _new_rules()
	_rig(rules, {
		P1: [_card(RED, REVERSE), _filler],
		P2: [_card(RED, UnoDeck.F.N1)], P3: [_card(RED, UnoDeck.F.N2)],
	}, _card(RED, UnoDeck.F.N5), RED, P1)
	rules.play_card(P1, _card(RED, REVERSE))
	_check("方向反转", rules.direction() == -1, "%d" % rules.direction())
	_check("反转后轮到上家", rules.current_player() == P3, "%d" % rules.current_player())

	# +2：下家摸两张并跳过
	rules = _new_rules()
	_rig(rules, {
		P1: [_card(RED, DRAW2), _filler],
		P2: [_card(RED, UnoDeck.F.N1)], P3: [_card(RED, UnoDeck.F.N2)],
	}, _card(RED, UnoDeck.F.N5), RED, P1, [
		_card(BLUE, UnoDeck.F.N1), _card(BLUE, UnoDeck.F.N2),
	])
	rules.play_card(P1, _card(RED, DRAW2))
	_check("+2 记在账上", rules.pending_draw() == 2, "%d" % rules.pending_draw())
	var before := rules.hand_count(P2)
	var drew := rules.draw_card(P2)
	_check("下家摸两张", rules.hand_count(P2) == before + 2, "%d" % rules.hand_count(P2))
	_check("罚抽标记生效", bool(drew.get("penalty", false)))
	_check("摸完轮到再下一家", rules.current_player() == P3, "%d" % rules.current_player())

	# 万能牌必须先选颜色
	rules = _new_rules()
	_rig(rules, {
		P1: [_card(WILD, WILD_FACE), _filler],
		P2: [_card(RED, UnoDeck.F.N1)], P3: [_card(RED, UnoDeck.F.N2)],
	}, _card(RED, UnoDeck.F.N5), RED, P1)
	var pick := rules.play_card(P1, _card(WILD, WILD_FACE))
	_check("万能牌要求选色", bool(pick.get("needs_color", false)), str(pick))
	_check("进入选色阶段", rules.phase() == UnoRules.Phase.CHOOSING_COLOR)
	_check("选色期间别人不能出牌", not rules.can_play(P2, _card(RED, UnoDeck.F.N1)))
	rules.choose_color(P1, GREEN)
	_check("选色后颜色生效", rules.active_color() == GREEN, "%d" % rules.active_color())
	_check("选色后回到出牌阶段", rules.phase() == UnoRules.Phase.PLAYING)
	_check("选色后轮转到下家", rules.current_player() == P2)

	# 出完最后一张就赢
	rules = _new_rules()
	_rig(rules, {
		P1: [_card(RED, UnoDeck.F.N5)], P2: [_card(RED, UnoDeck.F.N1)], P3: [_card(RED, UnoDeck.F.N2)],
	}, _card(RED, UnoDeck.F.N3), RED, P1)
	rules.play_card(P1, _card(RED, UnoDeck.F.N5))
	_check("出完最后一张即结束", rules.is_finished())
	_check("赢家正确", rules.winner() == P1, "%d" % rules.winner())


# ---------------------------------------------------------------- 叠牌

func _test_stacking() -> void:
	print("\n-- 叠牌家规 --")

	# 默认（关）：+2 不能叠
	var rules := _new_rules()
	_rig(rules, {
		P1: [_card(RED, DRAW2), _filler],
		P2: [_card(BLUE, DRAW2), _filler], P3: [_card(RED, UnoDeck.F.N2)],
	}, _card(RED, UnoDeck.F.N5), RED, P1, [_card(YELLOW, UnoDeck.F.N1)])
	rules.play_card(P1, _card(RED, DRAW2))
	_check("默认不允许叠 +2", not rules.can_play(P2, _card(BLUE, DRAW2)))

	# 打开叠牌：+2 可以叠 +2
	rules = _new_rules({"stacking": true})
	_rig(rules, {
		P1: [_card(RED, DRAW2), _filler],
		P2: [_card(BLUE, DRAW2), _filler], P3: [_card(RED, UnoDeck.F.N2)],
	}, _card(RED, UnoDeck.F.N5), RED, P1, [
		_card(YELLOW, UnoDeck.F.N1), _card(YELLOW, UnoDeck.F.N2),
		_card(YELLOW, UnoDeck.F.N3), _card(YELLOW, UnoDeck.F.N4),
	])
	rules.play_card(P1, _card(RED, DRAW2))
	_check("开了之后 +2 可叠", rules.can_play(P2, _card(BLUE, DRAW2)))
	rules.play_card(P2, _card(BLUE, DRAW2))
	_check("叠牌累计到 4", rules.pending_draw() == 4, "%d" % rules.pending_draw())
	var before := rules.hand_count(P3)
	rules.draw_card(P3)
	_check("第三家吞下 4 张", rules.hand_count(P3) == before + 4, "%d" % rules.hand_count(P3))

	# +4 不能叠在 +2 上（两种牌不能混叠）
	rules = _new_rules({"stacking": true, "stack_wild4": true})
	_rig(rules, {
		P1: [_card(RED, DRAW2), _filler],
		P2: [_card(WILD, WILD4), _filler], P3: [_card(RED, UnoDeck.F.N2)],
	}, _card(RED, UnoDeck.F.N5), RED, P1, [_card(YELLOW, UnoDeck.F.N1)])
	rules.play_card(P1, _card(RED, DRAW2))
	_check("+4 不能叠在 +2 上", not rules.can_play(P2, _card(WILD, WILD4)))


# ---------------------------------------------------------------- 摸牌

func _test_draw_rules() -> void:
	print("\n-- 摸牌与过牌 --")

	# 摸到的牌不能出，自动跳过
	var rules := _new_rules()
	_rig(rules, {
		P1: [_card(GREEN, UnoDeck.F.N9)], P2: [_card(RED, UnoDeck.F.N1)], P3: [_card(RED, UnoDeck.F.N2)],
	}, _card(RED, UnoDeck.F.N5), RED, P1, [_card(BLUE, UnoDeck.F.N7)])
	var res := rules.draw_card(P1)
	_check("摸到异色牌会自动跳过", bool(res.get("auto_passed", false)), str(res))
	_check("跳过之后轮到下家", rules.current_player() == P2, "%d" % rules.current_player())
	_check("跳过之后原玩家不能再摸", not rules.draw_card(P1).get("ok", false))

	# 摸到的牌能出：留在自己手上，回合不结束
	rules = _new_rules()
	_rig(rules, {
		P1: [_card(GREEN, UnoDeck.F.N9)], P2: [_card(RED, UnoDeck.F.N1)], P3: [_card(RED, UnoDeck.F.N2)],
	}, _card(RED, UnoDeck.F.N5), RED, P1, [_card(RED, UnoDeck.F.N7)])
	res = rules.draw_card(P1)
	_check("摸到能出的牌不自动跳过", not res.get("auto_passed", false), str(res))
	_check("摸完还是自己的回合", rules.current_player() == P1)
	_check("摸到的那张可以出", rules.can_play(P1, _card(RED, UnoDeck.F.N7)))
	_check("摸过之后可以主动过", rules.pass_turn(P1).get("ok", false))
	_check("过完轮到下家", rules.current_player() == P2)

	# 一轮只能摸一次
	rules = _new_rules()
	_rig(rules, {
		P1: [_card(GREEN, UnoDeck.F.N9)], P2: [_card(RED, UnoDeck.F.N1)], P3: [_card(RED, UnoDeck.F.N2)],
	}, _card(RED, UnoDeck.F.N5), RED, P1, [_card(RED, UnoDeck.F.N7), _card(RED, UnoDeck.F.N8)])
	rules.draw_card(P1)
	_check("同回合不能摸第二次", not rules.draw_card(P1).get("ok", false))


# ---------------------------------------------------------------- UNO

func _test_uno_calls() -> void:
	print("\n-- 喊 UNO 与抓人 --")

	var rules := _new_rules()
	_rig(rules, {
		P1: [_card(RED, UnoDeck.F.N5), _card(RED, UnoDeck.F.N6)],
		P2: [_card(RED, UnoDeck.F.N1)], P3: [_card(RED, UnoDeck.F.N2)],
	}, _card(RED, UnoDeck.F.N3), RED, P1, [_card(BLUE, UnoDeck.F.N1), _card(BLUE, UnoDeck.F.N2)])
	rules.play_card(P1, _card(RED, UnoDeck.F.N5))
	_check("剩一张时被标记", rules.uno_pending(P1))

	# 抓人：罚摸两张
	var before := rules.hand_count(P1)
	var caught := rules.catch_uno(P2, P1)
	_check("抓人成功", bool(caught.get("caught", false)), str(caught))
	_check("罚摸两张", rules.hand_count(P1) == before + 2, "%d" % rules.hand_count(P1))
	_check("抓完标记清掉", not rules.uno_pending(P1))

	# 自己喊了就不会被罚
	rules = _new_rules()
	_rig(rules, {
		P1: [_card(RED, UnoDeck.F.N5), _card(RED, UnoDeck.F.N6)],
		P2: [_card(RED, UnoDeck.F.N1)], P3: [_card(RED, UnoDeck.F.N2)],
	}, _card(RED, UnoDeck.F.N3), RED, P1, [_card(BLUE, UnoDeck.F.N1), _card(BLUE, UnoDeck.F.N2)])
	rules.play_card(P1, _card(RED, UnoDeck.F.N5))
	_check("自己喊 UNO", rules.say_uno(P1).get("ok", false))
	_check("喊完抓不到", not rules.catch_uno(P2, P1).get("ok", false))

	# 没到一张时不能抓
	rules = _new_rules()
	_rig(rules, {
		P1: [_card(RED, UnoDeck.F.N5)], P2: [_card(RED, UnoDeck.F.N1)], P3: [_card(RED, UnoDeck.F.N2)],
	}, _card(RED, UnoDeck.F.N3), RED, P1)
	_check("手牌多时抓不到", not rules.catch_uno(P2, P1).get("ok", false))
	_check("不能抓自己", not rules.catch_uno(P1, P1).get("ok", false))


# ---------------------------------------------------------------- 计分

func _test_scoring() -> void:
	print("\n-- 计分 --")
	_check("数字牌按面值", UnoRules.card_points(_card(RED, UnoDeck.F.N7)) == 7)
	_check("0 是 0 分", UnoRules.card_points(_card(RED, UnoDeck.F.N0)) == 0)
	_check("跳过 20 分", UnoRules.card_points(_card(RED, SKIP)) == 20)
	_check("反转 20 分", UnoRules.card_points(_card(RED, REVERSE)) == 20)
	_check("+2 是 20 分", UnoRules.card_points(_card(RED, DRAW2)) == 20)
	_check("变色 50 分", UnoRules.card_points(_card(WILD, WILD_FACE)) == 50)
	_check("变色+4 是 50 分", UnoRules.card_points(_card(WILD, WILD4)) == 50)

	var rules := _new_rules()
	_rig(rules, {
		P1: [_card(RED, UnoDeck.F.N5)],
		P2: [_card(BLUE, UnoDeck.F.N9), _card(WILD, WILD_FACE)],
		P3: [_card(GREEN, SKIP)],
	}, _card(RED, UnoDeck.F.N3), RED, P1)
	rules.play_card(P1, _card(RED, UnoDeck.F.N5))
	var scores := rules.round_scores()
	_check("赢家拿到其他人手牌总分", int(scores.get(P1, 0)) == 9 + 50 + 20,
		"%d" % int(scores.get(P1, 0)))
	_check("没赢的人 0 分", int(scores.get(P2, 0)) == 0 and int(scores.get(P3, 0)) == 0)


# ---------------------------------------------------------------- 牌堆

func _test_pile_recycle() -> void:
	print("\n-- 牌堆洗回 --")
	var rules := _new_rules()
	_rig(rules, {
		P1: [_card(GREEN, UnoDeck.F.N9)], P2: [_card(RED, UnoDeck.F.N1)], P3: [_card(RED, UnoDeck.F.N2)],
	}, _card(RED, UnoDeck.F.N5), RED, P1, [])
	# 牌堆空了，但弃牌堆里还有历史牌，应该洗回来继续摸
	var buried: Array[int] = []
	for i in 12:
		buried.append(_card(BLUE, i % 10))
	rules._discard = ([_card(RED, UnoDeck.F.N5)] as Array[int])
	for card in buried:
		rules._discard.insert(0, card)
	var res := rules.draw_card(P1)
	_check("牌堆空了会洗回弃牌堆", res.get("ok", false), str(res))
	_check("洗回后确实摸到了牌", res.get("cards", []).size() == 1, str(res.get("cards", [])))


func _test_determinism() -> void:
	print("\n-- 随机种子 --")
	var a := _new_rules({}, 12345)
	var b := _new_rules({}, 12345)
	_check("同一个种子发同样的牌", a.hand_of(P1) == b.hand_of(P1)
		and a.hand_of(P2) == b.hand_of(P2), str(a.hand_of(P1)))
	var c := _new_rules({}, 54321)
	_check("不同种子发不同的牌", a.hand_of(P1) != c.hand_of(P1))
	_check("起始牌也一致", a.top_card() == b.top_card())


# ---------------------------------------------------------------- 汇总

func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  [OK]   ", label)
	else:
		_failed += 1
		print("  [FAIL] ", label, "   ", detail)


func _finish() -> void:
	print("\n=== 通过 %d，失败 %d ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
