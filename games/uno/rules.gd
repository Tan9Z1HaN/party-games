class_name UnoRules
extends RefCounted

## UNO 规则引擎。纯逻辑：不碰网络、不碰 UI、不碰场景树。
##
## 这样它才能被 headless 单测完整覆盖，也才能在主机和客户端共用
## （客户端只拿它做「这张牌我能不能出」的预判，判定仍在主机）。
##
## 所有会改变状态的方法都返回 `{ok, error}` 而不是 push_error——
## 主机会收到来自客户端的非法请求，那是正常情况，不该刷屏。
##
## **家庭规则里 7-0 和抢出还没做**，所以也没写进配置表。
## 与其让房主打开一个不起作用的开关，不如先不提供。

const HAND_SIZE := 7

## 抽牌时的防御上限。牌堆反复洗回理论上可能死循环。
const MAX_DRAW_GUARD := 300

## 家规默认值。以官方规则为准，家规一律默认关。
const DEFAULT_RULES := {
	"stacking": false,      ## +2 可叠 +2
	"stack_wild4": false,   ## +4 可叠 +4（和叠 +2 相互独立）
	"draw_and_play": true,  ## 摸到的牌能出就允许立刻出
	"auto_pass": true,      ## 摸到的牌不能出就自动跳过
}

enum Phase {
	PLAYING,
	CHOOSING_COLOR,   ## 有人打出万能牌（或起始牌是万能），等他指定颜色
	FINISHED,
}


var _order: Array[int] = []
var _hands := {}                 ## peer_id -> Array[int]
var _draw_pile: Array[int] = []
var _discard: Array[int] = []
var _cursor := 0                 ## 当前玩家在 _order 里的下标
var _direction := 1              ## 1 顺时针（按下标递增），-1 逆时针
var _active_color := UnoDeck.C.RED
var _drawn_this_turn := false
var _pending_draw := 0           ## 累计待摸张数（叠牌的结果）
var _pending_face := -1          ## 累计的是 +2 还是 +4，防止两种牌混叠
var _uno_flag := {}              ## peer_id -> true 表示「只剩 1 张但还没喊」
var _phase := Phase.PLAYING
var _color_chooser := 0
var _winner := 0
var _rules := {}
var _rng := RandomNumberGenerator.new()


# ---------------------------------------------------------------- 初始化

func setup(players: Array, cfg: Dictionary = {}, seed_value := 0) -> void:
	_order.clear()
	for entry in players:
		_order.append(int(entry["peer_id"]))
	_hands.clear()
	for peer_id in _order:
		_hands[peer_id] = [] as Array[int]

	_rules = DEFAULT_RULES.duplicate()
	for key in cfg:
		if _rules.has(key):
			_rules[key] = cfg[key]

	if seed_value == 0:
		_rng.randomize()
	else:
		_rng.seed = seed_value

	_draw_pile = UnoDeck.shuffled(seed_value)
	_discard.clear()
	_cursor = 0
	_direction = 1
	_drawn_this_turn = false
	_pending_draw = 0
	_pending_face = -1
	_uno_flag.clear()
	_phase = Phase.PLAYING
	_color_chooser = 0
	_winner = 0

	# 发牌：一圈一圈发，跟真人发牌一致
	for i in HAND_SIZE:
		for peer_id in _order:
			var card := _draw_from_pile()
			if card >= 0:
				_hands[peer_id].append(card)

	_open_first_card()


## 翻起始牌。官方的几条特殊规则都在这里。
func _open_first_card() -> void:
	var card := _draw_from_pile()
	while card >= 0 and UnoDeck.face_of(card) == UnoDeck.F.WILD4:
		# 官方：起始牌是 +4 就塞回牌堆重翻
		_draw_pile.insert(0, card)
		card = _draw_from_pile()
	if card < 0:
		return

	_discard.append(card)
	_active_color = UnoDeck.color_of(card)

	match UnoDeck.face_of(card):
		UnoDeck.F.WILD:
			# 起始牌是变色，第一个玩家指定颜色
			_phase = Phase.CHOOSING_COLOR
			_color_chooser = current_player()
		UnoDeck.F.SKIP:
			_advance(1)
		UnoDeck.F.REVERSE:
			_direction = -1
			_advance(1)
		UnoDeck.F.DRAW2:
			_pending_draw = 2
			_pending_face = UnoDeck.F.DRAW2


# ---------------------------------------------------------------- 查询

func players() -> Array[int]:
	return _order.duplicate()


func phase() -> Phase:
	return _phase


func is_finished() -> bool:
	return _phase == Phase.FINISHED


func winner() -> int:
	return _winner


func current_player() -> int:
	if _order.is_empty():
		return 0
	return _order[_cursor]


func direction() -> int:
	return _direction


func active_color() -> int:
	return _active_color


func top_card() -> int:
	if _discard.is_empty():
		return -1
	return _discard[_discard.size() - 1]


func hand_of(peer_id: int) -> Array[int]:
	if not _hands.has(peer_id):
		return [] as Array[int]
	return (_hands[peer_id] as Array[int]).duplicate()


func hand_count(peer_id: int) -> int:
	if not _hands.has(peer_id):
		return 0
	return (_hands[peer_id] as Array[int]).size()


func hand_counts() -> Dictionary:
	var out := {}
	for peer_id in _order:
		out[peer_id] = hand_count(peer_id)
	return out


func draw_pile_size() -> int:
	return _draw_pile.size()


func pending_draw() -> int:
	return _pending_draw


## 只剩 1 张但还没喊 UNO 的人。别人可以抓他。
func uno_pending(peer_id: int) -> bool:
	return bool(_uno_flag.get(peer_id, false))


func color_chooser() -> int:
	return _color_chooser if _phase == Phase.CHOOSING_COLOR else 0


func rule(key: String) -> bool:
	return bool(_rules.get(key, false))


# ---------------------------------------------------------------- 合法性

## 现在轮到的这个人，这张牌能不能出。
## 注意这是**本回合**的判断；抢出之类的越回合操作没做。
func can_play(peer_id: int, card: int) -> bool:
	if _phase != Phase.PLAYING:
		return false
	if peer_id != current_player():
		return false
	if not (_hands.get(peer_id, []) as Array[int]).has(card):
		return false

	# 本回合已经摸过牌，就只能出刚摸到的那张（摸到即出）
	if _drawn_this_turn and not rule("draw_and_play"):
		return false

	return _card_acceptable(card)


## 只看牌面规则，不看是谁、轮到谁。
func _card_acceptable(card: int) -> bool:
	var face := UnoDeck.face_of(card)
	var color := UnoDeck.color_of(card)

	# 有累计罚抽时，只允许接着叠（家规开着才行）
	if _pending_draw > 0:
		if face == UnoDeck.F.DRAW2:
			return rule("stacking") and _pending_face == UnoDeck.F.DRAW2
		if face == UnoDeck.F.WILD4:
			return rule("stack_wild4") and _pending_face == UnoDeck.F.WILD4
		return false

	if color == UnoDeck.C.WILD:
		return true
	return color == _active_color or face == UnoDeck.face_of(top_card())


## 手上所有能出的牌。客户端用它做「哪几张可以点」的高亮。
func playable_cards(peer_id: int) -> Array[int]:
	var out: Array[int] = []
	for card in (_hands.get(peer_id, []) as Array[int]):
		if can_play(peer_id, card):
			out.append(card)
	return out


func has_playable(peer_id: int) -> bool:
	return not playable_cards(peer_id).is_empty()


# ---------------------------------------------------------------- 动作

## 出牌。万能牌必须带 chosen_color。
func play_card(peer_id: int, card: int, chosen_color := -1) -> Dictionary:
	if _phase == Phase.CHOOSING_COLOR:
		return _err("先指定颜色")
	if _phase != Phase.PLAYING:
		return _err("这一局已经结束了")
	if peer_id != current_player():
		return _err("还没轮到你")
	if not (_hands.get(peer_id, []) as Array[int]).has(card):
		return _err("手上没有这张牌")
	if not can_play(peer_id, card):
		return _err("这张牌现在不能出")

	var face := UnoDeck.face_of(card)
	if UnoDeck.is_wild(card):
		if chosen_color < 0 or chosen_color > UnoDeck.C.BLUE:
			# 先切到选色阶段，收齐颜色再继续
			_phase = Phase.CHOOSING_COLOR
			_color_chooser = peer_id
			_pending_play = card
			return {"ok": true, "needs_color": true}

	_commit_play(peer_id, card, chosen_color)
	return {"ok": true}


## 打出万能牌后指定的颜色。也可以用于「起始牌是万能」那种情况。
func choose_color(peer_id: int, color: int) -> Dictionary:
	if _phase != Phase.CHOOSING_COLOR:
		return _err("现在不需要选颜色")
	if peer_id != _color_chooser:
		return _err("不是你选")
	if color < 0 or color > UnoDeck.C.BLUE:
		return _err("颜色不合法")

	_active_color = color
	_phase = Phase.PLAYING
	if _pending_play >= 0:
		var card := _pending_play
		_pending_play = -1
		_commit_play(peer_id, card, color)
		return {"ok": true}
	# 起始牌是万能的情况：颜色定完直接开打
	_color_chooser = 0
	return {"ok": true}


var _pending_play := -1


## 真正把牌落到弃牌堆并结算效果。
func _commit_play(peer_id: int, card: int, chosen_color: int) -> void:
	var hand: Array[int] = _hands[peer_id]
	hand.erase(card)
	_discard.append(card)

	var face := UnoDeck.face_of(card)
	if UnoDeck.is_wild(card):
		_active_color = chosen_color if chosen_color >= 0 else UnoDeck.C.RED
	else:
		_active_color = UnoDeck.color_of(card)

	_drawn_this_turn = false

	# 出完这张就赢了，剩下的效果都不用管
	if hand.is_empty():
		_winner = peer_id
		_phase = Phase.FINISHED
		_uno_flag.erase(peer_id)
		return

	# 剩 1 张：标记成「还没喊」，别人可以抓
	if hand.size() == 1:
		_uno_flag[peer_id] = true
	else:
		_uno_flag.erase(peer_id)

	match face:
		UnoDeck.F.SKIP:
			_advance(2)
		UnoDeck.F.REVERSE:
			_direction = -_direction
			_advance(1)
		UnoDeck.F.DRAW2:
			_pending_draw += 2
			_pending_face = UnoDeck.F.DRAW2
			_advance(1)
		UnoDeck.F.WILD4:
			_pending_draw += 4
			_pending_face = UnoDeck.F.WILD4
			_advance(1)
		_:
			_advance(1)


## 摸牌。有累计罚抽时一次摸完并跳过回合。
func draw_card(peer_id: int) -> Dictionary:
	if _phase == Phase.CHOOSING_COLOR:
		return _err("先指定颜色")
	if _phase != Phase.PLAYING:
		return _err("这一局已经结束了")
	if peer_id != current_player():
		return _err("还没轮到你")
	if _drawn_this_turn and _pending_draw == 0:
		return _err("本回合已经摸过了")

	# 罚抽：一次摸完，回合直接过
	if _pending_draw > 0:
		var total := _pending_draw
		var taken: Array[int] = []
		var guard := 0
		while taken.size() < total and guard < MAX_DRAW_GUARD:
			guard += 1
			var card := _draw_from_pile()
			if card < 0:
				break
			taken.append(card)
		(_hands[peer_id] as Array[int]).append_array(taken)
		_pending_draw = 0
		_pending_face = -1
		_drawn_this_turn = false
		_uno_flag.erase(peer_id)
		_advance(1)
		return {"ok": true, "cards": taken, "penalty": true}

	var got := _draw_from_pile()
	if got < 0:
		return _err("牌堆空了")
	(_hands[peer_id] as Array[int]).append(got)
	_uno_flag.erase(peer_id)
	_drawn_this_turn = true

	# 摸到不能出且家规允许自动跳过
	var playable := rule("draw_and_play") and _card_acceptable(got)
	if not playable and rule("auto_pass"):
		_drawn_this_turn = false
		_advance(1)
		return {"ok": true, "cards": [got], "auto_passed": true}

	return {"ok": true, "cards": [got], "playable": playable}


## 摸完牌不想出，主动过。只有摸过牌才能过。
func pass_turn(peer_id: int) -> Dictionary:
	if _phase != Phase.PLAYING:
		return _err("现在不能过")
	if peer_id != current_player():
		return _err("还没轮到你")
	if not _drawn_this_turn:
		return _err("没摸牌就不能过")
	_drawn_this_turn = false
	_advance(1)
	return {"ok": true}


## 喊 UNO。剩 1 张时喊，之后别人就不能抓你了。
func say_uno(peer_id: int) -> Dictionary:
	if not _uno_flag.has(peer_id):
		return _err("现在不用喊")
	_uno_flag.erase(peer_id)
	return {"ok": true}


## 抓别人没喊 UNO。抓到罚摸 2 张。
func catch_uno(catcher: int, target: int) -> Dictionary:
	if catcher == target:
		return _err("不能抓自己")
	if not _uno_flag.has(target):
		return _err("他没违规")

	_uno_flag.erase(target)
	var taken: Array[int] = []
	for i in 2:
		var card := _draw_from_pile()
		if card < 0:
			break
		taken.append(card)
	(_hands[target] as Array[int]).append_array(taken)
	return {"ok": true, "caught": true, "cards": taken, "catcher": catcher, "target": target}


# ---------------------------------------------------------------- 结算

## 一张牌值多少分。数字牌就是面值（0 是 0 分），功能牌 20，万能牌 50。
static func card_points(card: int) -> int:
	var face := UnoDeck.face_of(card)
	if face <= UnoDeck.F.N9:
		return face
	if face == UnoDeck.F.WILD or face == UnoDeck.F.WILD4:
		return 50
	return 20


func hand_points(peer_id: int) -> int:
	var total := 0
	for card in (_hands.get(peer_id, []) as Array[int]):
		total += card_points(card)
	return total


## 单局结算：赢家拿到其他所有人手上牌的总分。
func round_scores() -> Dictionary:
	var out := {}
	for peer_id in _order:
		out[peer_id] = 0
	if _winner == 0:
		return out
	var total := 0
	for peer_id in _order:
		if peer_id != _winner:
			total += hand_points(peer_id)
	out[_winner] = total
	return out


# ---------------------------------------------------------------- 内部

func _advance(steps: int) -> void:
	if _order.is_empty():
		return
	# 两人局里 Reverse 视同 Skip，所以方向改变后仍然只前进一格，
	# 但起始牌是 Reverse 时也要当成跳过——两条都是官方规则。
	var size := _order.size()
	if _direction == -1:
		_cursor = posmod(_cursor - steps, size)
	else:
		_cursor = posmod(_cursor + steps, size)


func _draw_from_pile() -> int:
	if _draw_pile.is_empty():
		_recycle_discard()
	if _draw_pile.is_empty():
		return -1
	return _draw_pile.pop_back()


## 牌堆抽空时，把弃牌堆除最上面一张外洗回牌堆。
func _recycle_discard() -> void:
	if _discard.size() <= 1:
		return
	var top := _discard[_discard.size() - 1]
	var recycled: Array[int] = []
	for i in range(_discard.size() - 1):
		# 洗回去的万能牌不用重置颜色，它本来就是万能
		recycled.append(_discard[i])
	_discard = [top] as Array[int]
	for i in range(recycled.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp := recycled[i]
		recycled[i] = recycled[j]
		recycled[j] = tmp
	_draw_pile.append_array(recycled)


func _err(message: String) -> Dictionary:
	return {"ok": false, "error": message}
