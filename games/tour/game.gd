class_name TourGame
extends MiniGame

## 环游中国的房间层适配。
##
## 两端职责和 UNO 那边一样：**房主跑规则**，收意图、校验、把状态广播出去；
## **客户端不跑规则**，只把主机发来的状态渲染出来。
##
## 比 UNO 简单的地方：大富翁没有隐藏信息，所以**不需要单发**——
## 快照就是完整状态，人手一份。

## 状态变了，界面重画。两端都会发。
signal state_changed()

const ID := "tour"
## 电脑对手思考的间隔。画面那边会等动画放完再让 AI 动下一步（见 main.gd
## 的 _is_animating），所以这里不用再留很长——0.5 秒够看清"轮到谁"了。
const AI_DELAY := 0.5

var _players: Array = []      ## [{peer_id, name, is_ai}]
var _cfg := {}
var _room: Room = null
var _rules: TourRules = null  ## 只有房主有
var _client := {}             ## 只有客户端有：主机发来的状态
var _ai_timer := 0.0
var _seed := 0


func get_meta_info() -> Dictionary:
	return {
		"id": ID,
		"name": tr("环游中国"),
		"min_players": 2,
		"max_players": 6,
		"est_minutes": 12,
		"scene": "res://games/tour/main.tscn",
		"solo": true,
		"online": true,
	}


func get_config_schema() -> Array:
	return [
		{
			# 胜利条件是「把别人搞破产」，所以没有"打几轮"这回事。
			# 这一项是保险丝：万一谁都不破产，到上限就按资产结算。
			"id": "max_rounds", "label": tr("回合上限（0 为不限）"), "type": "int",
			"default": 0, "min": 0, "max": 100,
			"help": tr("正常局靠破产结束。这一项只是防止一局无限拖下去"),
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
	_cfg = {}
	for item in get_config_schema():
		_cfg[item["id"]] = item["default"]
	for key in cfg:
		_cfg[key] = cfg[key]
	_rules = null
	_client = {}
	_ai_timer = 0.0
	if _seed == 0:
		_seed = int(Time.get_unix_time_from_system()) % 100000


func start_round() -> void:
	if not _is_authority():
		return
	var roster: Array = []
	for entry in _players:
		roster.append({"peer_id": int(entry["peer_id"]), "name": String(entry["name"])})
	_rules = TourRules.new()
	_rules.setup(roster, _cfg, _seed)
	state_changed.emit()


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
	TourAi.act(_rules, current)
	state_changed.emit()


func on_player_input(peer_id: int, payload: PackedByteArray) -> void:
	if not _is_authority() or _rules == null:
		return
	if _slot_of(peer_id) < 0:
		return
	var msg := TourMessages.decode(payload)
	if msg.is_empty():
		return
	match int(msg["action"]):
		TourMessages.Action.ROLL: _rules.roll(peer_id)
		TourMessages.Action.BUY: _rules.buy(peer_id)
		TourMessages.Action.UPGRADE: _rules.upgrade(peer_id)
		TourMessages.Action.DECLINE: _rules.decline(peer_id)
		TourMessages.Action.PAY_FINE: _rules.pay_fine(peer_id)
		TourMessages.Action.TAX_FLAT: _rules.pay_tax_flat(peer_id)
		TourMessages.Action.TAX_PERCENT: _rules.pay_tax_percent(peer_id)
	state_changed.emit()


func on_player_left(peer_id: int) -> void:
	if not _is_authority() or _rules == null:
		return
	# 走的人算破产：地释放，回合交棒。不这么做的话整局会卡在他身上。
	_rules.eliminate(peer_id)
	state_changed.emit()


func snapshot() -> Dictionary:
	if not _is_authority() or _rules == null:
		return {}
	return _rules.snapshot()


## 界面读这个。房主从本地规则生成，客户端用主机发来的镜像。
func state() -> Dictionary:
	if _rules == null or not _is_authority():
		return _client
	return _rules.snapshot()


func apply_snapshot(data: Dictionary) -> void:
	if _is_authority() or data.is_empty():
		return
	_apply_snapshot_data(data)


## 抽出来备测：apply_snapshot 开头的权威端守卫会让没有 peer 的测试环境直接返回。
func _apply_snapshot_data(data: Dictionary) -> void:
	if data.is_empty():
		return
	_client = data.duplicate(true)
	state_changed.emit()


## 把本机玩家的操作送出去。联机交给房间层，单机直接本地处理。
func submit(payload: PackedByteArray) -> void:
	if _room != null and _room.is_in_room():
		_room.send_game_input(payload)
		return
	if not _is_authority():
		push_error("TourGame 还没拿到 Room，玩家的操作发不出去")
		return
	on_player_input(local_peer_id(), payload)


func bind_room(room: Room) -> void:
	_room = room


func local_peer_id() -> int:
	if _is_networked():
		return multiplayer.get_unique_id()
	for entry in _players:
		if not bool(entry.get("is_ai", false)):
			return int(entry["peer_id"])
	return 0


func is_finished() -> bool:
	if _rules != null and _is_authority():
		return _rules.is_finished()
	return bool(_client.get("finished", false))


func get_results() -> Array:
	var rows: Array = []
	for row in state().get("players", []):
		rows.append({"peer_id": int(row["peer_id"]), "score": int(row["assets"])})
	rows.sort_custom(func(a, b): return int(a["score"]) > int(b["score"]))
	return rows


func get_replay_data() -> Dictionary:
	return {"game": ID, "standings": state().get("players", [])}


func rules() -> TourRules:
	return _rules


func _slot_of(peer_id: int) -> int:
	for i in _players.size():
		if int(_players[i]["peer_id"]) == peer_id:
			return i
	return -1


func _is_ai(peer_id: int) -> bool:
	var idx := _slot_of(peer_id)
	return idx >= 0 and bool(_players[idx].get("is_ai", false))


func _is_networked() -> bool:
	if not is_inside_tree():
		return false
	var mp := multiplayer
	return mp != null and mp.multiplayer_peer != null


func _is_authority() -> bool:
	if not is_inside_tree():
		return true
	var mp := multiplayer
	if mp == null or mp.multiplayer_peer == null:
		return true
	return mp.is_server()
