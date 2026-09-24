class_name UnoGame
extends MiniGame

## UNO 的房间层适配。规则在 rules.gd（纯逻辑），界面在 main.gd，
## 这一层负责把两边接起来，并把「谁是权威端」这件事挡在界面之外。
##
## 两端职责：
##   **房主**跑 UnoRules：收意图、校验、算结果，然后广播公开状态、
##   **单发**每个人的手牌。
##   **客户端不跑规则**，只把房主发来的东西渲染出来。
##
## 为什么界面要认「状态字典」而不是直接认 UnoRules：
## 单机时状态从本地规则生成，联机时从主机报文生成，界面只认这一份结构，
## 就不会出现「单机版和联机版长得不一样、改一个忘一个」。
##
## 单机不走房间：main.gd 直接 new 一个 UnoGame，自己 tick()，
## 玩家信息里带 is_ai，AI 回合由 tick() 推。
##
## **手牌只单发，绝不进广播**——见 messages.gd 的说明。

## 状态变了，界面重画。两端都会发。
signal state_changed()
## 有人出了牌。界面用它放出牌动画。
signal event_played(peer_id: int, card: int)
## 有人摸了牌。界面用它放摸牌动画。
signal event_drew(peer_id: int, count: int)
## 状态行的文案。房主生成、广播，两端看到同一句话。
signal event_log(text: String)

const ID := "uno"

## AI 每步之间的停顿，太快看不清它在干什么
const AI_DELAY := 0.85

var _players: Array = []          ## [{peer_id, name, is_ai}]
var _cfg := {}
var _room: Room = null

var _rules: UnoRules = null       ## 只有权威端有
var _client_state := {}           ## 只有客户端有：主机发来的公开状态
var _client_hand: Array[int] = [] ## 只有客户端有：主机单发给我的手牌
var _ai_timer := 0.0
var _round := 0
## 打了万能牌还没定颜色时，先把牌记下来，选完颜色才播动画
var _pending_play_card := -1


# ------------------------------------------------------------------ 契约

func get_meta_info() -> Dictionary:
	return {
		"id": ID,
		"name": tr("UNO"),
		"min_players": 2,
		"max_players": 8,
		"est_minutes": 10,
		"scene": "res://games/uno/main.tscn",
		"solo": true,        ## 支持单机对电脑
		"online": true,
	}


func get_config_schema() -> Array:
	return [
		{
			"id": "stacking", "label": tr("叠牌（+2 叠 +2）"),
			"type": "bool", "default": false,
		},
		{
			"id": "stack_wild4", "label": tr("+4 叠 +4"),
			"type": "bool", "default": false,
		},
		{
			"id": "draw_and_play", "label": tr("摸到能出就出"),
			"type": "bool", "default": true,
		},
		{
			"id": "auto_pass", "label": tr("摸到不能出自动过"),
			"type": "bool", "default": true,
		},
	]


func setup(players: Array, cfg: Dictionary) -> void:
	_players = []
	for entry in players:
		_players.append({
			"peer_id": int(entry["peer_id"]),
			"name": String(entry.get("name", "?")),
			"is_ai": bool(entry.get("is_ai", false)),
		})
	_cfg = _merged(cfg)
	_rules = null
	_client_state = {}
	_client_hand = []
	_round = 0
	_pending_play_card = -1


## 发牌开打。UNO 的「一回合」就是一整局，所以重开一局走的也是这里。
func start_round() -> void:
	if not _is_authority():
		return
	_round += 1
	_ai_timer = 0.0
	_pending_play_card = -1
	_rules = UnoRules.new()
	_rules.setup(_players, _cfg, 0)
	_log(tr("开局。桌面上是 %s") % UnoDeck.describe(_rules.top_card()))
	_publish()


func tick(delta: float) -> void:
	if not _is_authority() or _rules == null or _rules.is_finished():
		return
	var current := _rules.current_player()
	if not _is_ai(current):
		_ai_timer = 0.0
		return
	_ai_timer += delta
	if _ai_timer < AI_DELAY:
		return
	_ai_timer = 0.0
	_ai_step(current)


func on_player_input(peer_id: int, payload: PackedByteArray) -> void:
	if not _is_authority() or _rules == null:
		return
	if _slot_of(peer_id) < 0:
		return
	var msg := UnoMessages.decode(payload)
	if msg.is_empty():
		return

	match int(msg["action"]):
		UnoMessages.Action.PLAY:
			_do_play(peer_id, int(msg["card"]), int(msg.get("color", UnoMessages.NO_COLOR)))
		UnoMessages.Action.DRAW:
			_do_draw(peer_id)
		UnoMessages.Action.PASS:
			_do_pass(peer_id)
		UnoMessages.Action.SAY_UNO:
			_do_say_uno(peer_id)
		UnoMessages.Action.CHOOSE_COLOR:
			_do_choose_color(peer_id, int(msg["color"]))


func on_player_left(peer_id: int) -> void:
	if not _is_authority() or _rules == null:
		return
	_rules.remove_player(peer_id)
	var idx := _slot_of(peer_id)
	if idx >= 0:
		_players.remove_at(idx)
	_log(tr("%s 离开了") % _name_of(peer_id))
	_publish()


func is_finished() -> bool:
	if _rules != null and _is_authority():
		return _rules.is_finished()
	return bool(_client_state.get("finished", false))


func get_results() -> Array:
	var scores: Dictionary = state().get("scores", {})
	var rows: Array = []
	for peer_id in scores:
		rows.append({"peer_id": int(peer_id), "score": int(scores[peer_id])})
	rows.sort_custom(func(a, b): return int(a["score"]) > int(b["score"]))
	return rows


func get_replay_data() -> Dictionary:
	var s := state()
	return {
		"game": ID,
		"winner": int(s.get("winner", 0)),
		"scores": s.get("scores", {}),
	}


# ------------------------------------------------------------------ 状态

## 交给网络层广播的公开状态。**不含任何人的手牌。**
func snapshot() -> Dictionary:
	if not _is_authority() or _rules == null:
		return {}
	return _public_state()


## 界面读这个。单机/房主从本地规则生成，客户端用主机发来的镜像。
func state() -> Dictionary:
	# 客户端没有规则对象，手里只有主机发来的镜像；
	# 权威端还没开局（_rules 为 null）时也是空的。
	if _rules == null or not _is_authority():
		return _client_state
	var out := _public_state()
	out["my_hand"] = _rules.hand_of(local_peer_id())
	return out


func apply_snapshot(data: Dictionary) -> void:
	if _is_authority() or data.is_empty():
		return
	_apply_snapshot_data(data)


## 实际套用快照。从 apply_snapshot 里抽出来，是因为开头那道权威端守卫
## 在单机/测试环境（没有 multiplayer peer，_is_authority() 恒为真）会
## 直接把客户端这条路径挡掉，等于永远测不到它。
func _apply_snapshot_data(data: Dictionary) -> void:
	if data.is_empty():
		return
	_client_state = data.duplicate(true)
	_client_state["my_hand"] = _client_hand
	state_changed.emit()


## 收到房主发来的报文（广播和单发都走这里）。
## 只更新表现，不做任何判定。
func on_remote_message(payload: PackedByteArray) -> void:
	if _is_authority():
		return
	_apply_remote_message_data(payload)


## 同上：拆出来备测。
func _apply_remote_message_data(payload: PackedByteArray) -> void:
	var msg := UnoMessages.decode(payload)
	if msg.is_empty():
		return
	match int(msg["action"]):
		UnoMessages.Action.SET_HAND:
			# 必须是带类型的数组：直接赋 Array 会撞上 Array[int] 的类型检查，
			# 报错但不中断，手牌就这么静默地一直是空的。
			var cards: Array[int] = []
			for value in msg["cards"]:
				cards.append(int(value))
			_client_hand = cards
			_client_state["my_hand"] = _client_hand
			state_changed.emit()
		UnoMessages.Action.PLAYED:
			event_played.emit(int(msg["peer_id"]), int(msg["card"]))
		UnoMessages.Action.DREW:
			event_drew.emit(int(msg["peer_id"]), int(msg["count"]))
		UnoMessages.Action.LOG, UnoMessages.Action.REJECT:
			event_log.emit(String(msg["text"]))


# ------------------------------------------------------------------ 输入路由

## 把本机玩家的操作送出去。联机时交给房间层转给房主，
## 单机时直接本地处理——两个入口共用同一段校验代码。
func submit(payload: PackedByteArray) -> void:
	if _room != null and _room.is_in_room():
		_room.send_game_input(payload)
		return
	if not _is_authority():
		# 客户端必须先把房间交进这一层（bind_room），否则操作会石沉大海、
		# 而这看起来跟"点了没反应"一模一样，非常难查。宁可喊出来。
		push_error("UnoGame 还没拿到 Room，玩家的操作发不出去")
		return
	on_player_input(local_peer_id(), payload)


## 联机时由界面把房间交给这一层，用来转发操作。
func bind_room(room: Room) -> void:
	_room = room


## 本机自己是哪个 peer。单机时是玩家列表里第一个不是 AI 的人。
func local_peer_id() -> int:
	if _is_networked():
		return multiplayer.get_unique_id()
	for entry in _players:
		if not bool(entry.get("is_ai", false)):
			return int(entry["peer_id"])
	return 0


func name_of(peer_id: int) -> String:
	return _name_of(peer_id)


## 这张牌现在出不出得了。**只用来给界面做提示**，权威端仍然会再判一次。
##
## 客户端没有规则对象，所以这里只按公开信息推：颜色或面值对得上，
## 或者是万能牌。有累计罚抽时保守返回 false——让玩家去试，
## 试错只会被拒一次，不会把状态弄坏。
func can_play(card: int) -> bool:
	var s := state()
	if s.is_empty() or bool(s.get("finished", false)):
		return false
	if int(s.get("current", 0)) != local_peer_id():
		return false
	if int(s.get("color_chooser", 0)) != 0:
		return false
	if int(s.get("pending_draw", 0)) > 0:
		return false
	if UnoDeck.is_wild(card):
		return true
	var top := int(s.get("top_card", -1))
	if top < 0:
		return true
	return UnoDeck.color_of(card) == int(s.get("active_color", -1)) \
		or UnoDeck.face_of(card) == UnoDeck.face_of(top)


func players() -> Array:
	return _players.duplicate()


# ------------------------------------------------------------------ 动作（权威端）

func _do_play(peer_id: int, card: int, chosen_color: int) -> void:
	var color := -1 if chosen_color == UnoMessages.NO_COLOR else chosen_color
	var res := _rules.play_card(peer_id, card, color)
	if not bool(res.get("ok", false)):
		_reject(peer_id, String(res.get("error", "")))
		return

	if bool(res.get("needs_color", false)):
		_pending_play_card = card
		if _is_ai(peer_id):
			# AI 不犹豫，直接定颜色
			_do_choose_color(peer_id, UnoAi.choose_color(_rules, peer_id))
		else:
			_log(tr("%s 出了 %s，等着定颜色…") % [
				_name_of(peer_id), UnoDeck.describe(card)])
			_publish()
		return

	_finish_play(peer_id, card)


func _do_choose_color(peer_id: int, color: int) -> void:
	var res := _rules.choose_color(peer_id, color)
	if not bool(res.get("ok", false)):
		_reject(peer_id, String(res.get("error", "")))
		return
	var card := _pending_play_card
	_pending_play_card = -1
	if card >= 0:
		_finish_play(peer_id, card)
		return
	# 起始牌就是万能牌的情况：只是定了个颜色，没人出牌
	_log(tr("%s 把颜色定成了 %s") % [
		_name_of(peer_id), UnoDeck.COLOR_NAMES[color]])
	_publish()


## 一张牌真正落到弃牌堆之后：写日志、放动画、把新状态推出去。
func _finish_play(peer_id: int, card: int) -> void:
	_log(tr("%s 出了 %s") % [_name_of(peer_id), UnoDeck.describe(card)])
	# 先推状态和手牌，再发动画事件。两者都走同一条可靠通道，
	# 顺序反过来的话，客户端会在手牌还没更新时就去放"牌从手里飞出去"的动画。
	_publish()
	_event(UnoMessages.encode_played(peer_id, card))
	event_played.emit(peer_id, card)


func _do_draw(peer_id: int) -> void:
	var res := _rules.draw_card(peer_id)
	if not bool(res.get("ok", false)):
		_reject(peer_id, String(res.get("error", "")))
		return
	var cards: Array = res.get("cards", [])
	var count := cards.size()
	if bool(res.get("penalty", false)):
		_log(tr("%s 吃了 %d 张罚牌") % [_name_of(peer_id), count])
	else:
		_log(tr("%s 摸了 %d 张") % [_name_of(peer_id), count])
	_publish()
	_event(UnoMessages.encode_drew(peer_id, count))
	event_drew.emit(peer_id, count)


func _do_pass(peer_id: int) -> void:
	var res := _rules.pass_turn(peer_id)
	if not bool(res.get("ok", false)):
		_reject(peer_id, String(res.get("error", "")))
		return
	_log(tr("%s 过牌") % _name_of(peer_id))
	_publish()


func _do_say_uno(peer_id: int) -> void:
	var res := _rules.say_uno(peer_id)
	if not bool(res.get("ok", false)):
		_reject(peer_id, String(res.get("error", "")))
		return
	_log(tr("%s 喊了 UNO！") % _name_of(peer_id))
	_publish()


# ------------------------------------------------------------------ AI

func _ai_step(peer_id: int) -> void:
	if _rules.phase() == UnoRules.Phase.CHOOSING_COLOR:
		_do_choose_color(peer_id, UnoAi.choose_color(_rules, peer_id))
		return

	var card := UnoAi.choose_card(_rules, peer_id)
	if card >= 0:
		_do_play(peer_id, card, -1)
		return

	var res := _rules.draw_card(peer_id)
	if not bool(res.get("ok", false)):
		return
	var cards: Array = res.get("cards", [])
	_log(tr("%s 摸了 %d 张") % [_name_of(peer_id), cards.size()])
	_publish()
	_event(UnoMessages.encode_drew(peer_id, cards.size()))
	event_drew.emit(peer_id, cards.size())

	# 摸到能出就接着出（家规 draw_and_play 开着时）
	if bool(res.get("playable", false)):
		var again := UnoAi.choose_card(_rules, peer_id)
		if again >= 0:
			_do_play(peer_id, again, -1)
			return
	# auto_pass 开着的话规则已经替他过回合了；没开就得自己过
	if _rules.current_player() == peer_id:
		_rules.pass_turn(peer_id)
	_publish()


# ------------------------------------------------------------------ 内部

func _public_state() -> Dictionary:
	var rows: Array = []
	for entry in _players:
		var pid := int(entry["peer_id"])
		rows.append({
			"peer_id": pid,
			"name": String(entry.get("name", "?")),
			"count": _rules.hand_count(pid),
		})
	return {
		"round": _round,
		"phase": _rules.phase(),
		"players": rows,
		"top_card": _rules.top_card(),
		"active_color": _rules.active_color(),
		"direction": _rules.direction(),
		"current": _rules.current_player(),
		"color_chooser": _rules.color_chooser(),
		"pending_draw": _rules.pending_draw(),
		"drawn_this_turn": _rules.drawn_this_turn(),
		"winner": _rules.winner(),
		"finished": _rules.is_finished(),
		"scores": _rules.round_scores(),
	}


## 权威端把状态推出去：重画界面、把手牌单发给每个人。
func _publish() -> void:
	_push_hands()
	state_changed.emit()


## 每个人的手牌只单发给他自己。牌少的时候一张牌一个字节，开销可以忽略。
##
## 这里**不加「有没有联网」的判断**：这两个信号只有房主的房间层才接，
## 单机时没人听，发了等于没发；而加了判断就等于把客户端那条路
## 挡在测试之外，之前就是因此漏掉了一个手牌同步的类型错误。
func _push_hands() -> void:
	var mine := local_peer_id()
	for entry in _players:
		var pid := int(entry["peer_id"])
		if pid == mine:
			continue
		to_player_requested.emit(pid, UnoMessages.encode_hand(_rules.hand_of(pid)))


func _log(text: String) -> void:
	event_log.emit(text)
	_event(UnoMessages.encode_log(text))


func _reject(peer_id: int, reason: String) -> void:
	if reason.is_empty():
		return
	var text := tr("不能这么做：%s") % reason
	# 单机（没有房间）没有人可以单发，直接写在自己的状态行上
	if peer_id == local_peer_id() or _room == null:
		event_log.emit(text)
		return
	to_player_requested.emit(peer_id, UnoMessages.encode_reject(text))


## 广播一条动作报文。房主自己不走网络，本地已经处理过了。
func _event(payload: PackedByteArray) -> void:
	broadcast_requested.emit(payload)


func _merged(cfg: Dictionary) -> Dictionary:
	var out := {}
	for item in get_config_schema():
		out[item["id"]] = item["default"]
	for key in cfg:
		out[key] = cfg[key]
	return out


func _slot_of(peer_id: int) -> int:
	for i in _players.size():
		if int(_players[i]["peer_id"]) == peer_id:
			return i
	return -1


func _name_of(peer_id: int) -> String:
	var idx := _slot_of(peer_id)
	if idx < 0:
		return tr("某个玩家")
	return String(_players[idx]["name"])


func _is_ai(peer_id: int) -> bool:
	var idx := _slot_of(peer_id)
	if idx < 0:
		return false
	return bool(_players[idx].get("is_ai", false))


func _is_networked() -> bool:
	if not is_inside_tree():
		return false
	var mp := multiplayer
	return mp != null and mp.multiplayer_peer != null


## 权威端 = 房主。不在场景树里（单元测试直接驱动）时按权威端算，
## 否则测试拿不到 multiplayer 会整个跑不起来。
func _is_authority() -> bool:
	if not is_inside_tree():
		return true
	var mp := multiplayer
	if mp == null or mp.multiplayer_peer == null:
		return true
	return mp.is_server()
