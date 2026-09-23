class_name DrawGuessGame
extends MiniGame

## 你画我猜的规则与流程。
##
## 设计原则：
## 1. **所有状态变更只在权威端发生**（房主，或者单机/热座时的本机）。
##    客户端只负责画和猜，然后把输入发给权威端。
## 2. **答案只告诉画手**。猜的人只拿到字数、类别和（超时过半后的）首字。
##    这条不能省——答案一旦下发到猜词者的机器上，抓包就能看到。
## 3. 计时全部走 tick()，不在这里自建 Timer，
##    这样暂停、重连恢复、超时托管都只有一个入口。
##
## 单机热座也能跑：没有多人 peer 时 _is_authority() 返回 true，
## 由画手点"某某猜对了"来推进猜对状态。

enum Phase {
	IDLE,
	CHOOSING,   ## 画手从三个候选词里选一个
	DRAWING,    ## 作画与猜词
	ROUND_END,  ## 本回合结算展示
	FINISHED,
}

const ID := "draw_guess"

const DEFAULT_ROUNDS := 3
const DEFAULT_ROUND_SECONDS := 80
const CHOOSE_SECONDS := 20.0
const ROUND_END_SECONDS := 7.0

## 画手得分：每个猜对的人给多少
const DRAWER_POINTS_PER_GUESSER := 50
## 全员猜对的额外奖励
const DRAWER_ALL_GUESSED_BONUS := 50
## 猜对的基础分与时间加成
const GUESS_BASE_POINTS := 100.0
const GUESS_TIME_FACTOR := 2.0

const CANDIDATE_COUNT := 3

## 笔迹限流：每秒允许多少字节，以及允许的瞬时突发量。
## 正常画画大约 120 字节/秒，这个上限很宽松，但能挡住恶意刷屏。
const STROKE_BYTES_PER_SEC := 4096.0
const STROKE_BURST := 8192.0

## 靠编辑距离判定"接近了"时的阈值
const NEAR_THRESHOLD := 1


# ------------------------------------------------------------------ UI 信号

signal phase_changed(phase: int, seconds: float)
signal candidates_offered(candidates: Array)
signal word_selected(word: String, category: String, difficulty: int)
signal guess_evaluated(peer_id: int, text: String, correct: bool, near: bool)
signal someone_guessed(peer_id: int, remaining: float)
signal round_settled(word: String, rows: Array)
signal scores_changed(scores: Dictionary)
signal stroke_forwarded(payload: PackedByteArray)


var _players: Array = []
var _scores := {}
var _cfg := {}
var _bank: WordBank

var _phase := Phase.IDLE
var _time_left := 0.0
var _round_index := 0
var _drawer_slot := -1

var _candidates: Array = []
var _entry: Dictionary = {}
var _correct_at := {}
var _used_words := PackedStringArray()
var _round_rows: Array = []
var _history: Array = []
var _stroke_budget := {}


# ------------------------------------------------------------------ 契约实现

func get_meta_info() -> Dictionary:
	return {
		"id": ID,
		"name": tr("你画我猜"),
		"min_players": 3,
		"max_players": 8,
		"est_minutes": 6,
		"scene": "res://games/draw_guess/main.tscn",
	}


func get_config_schema() -> Array:
	return [
		{
			"id": "rounds", "label": tr("回合数"), "type": "int",
			"default": DEFAULT_ROUNDS, "min": 1, "max": 12,
			"help": tr("每个回合换一名画手"),
		},
		{
			"id": "round_seconds", "label": tr("每回合时长（秒）"), "type": "int",
			"default": DEFAULT_ROUND_SECONDS, "min": 30, "max": 180,
		},
		{
			"id": "difficulty", "label": tr("词库难度"), "type": "enum", "default": 2,
			"options": [
				{"value": 1, "label": tr("简单")},
				{"value": 2, "label": tr("中等")},
				{"value": 3, "label": tr("困难")},
			],
		},
		{
			"id": "hints", "label": tr("开启提示"), "type": "bool", "default": true,
			"help": tr("时间过半后揭示首字"),
		},
	]


func setup(players: Array, cfg: Dictionary) -> void:
	_players = players.duplicate()
	_cfg = _merge_defaults(cfg)
	_bank = WordBank.load_default()

	_scores.clear()
	for p in _players:
		_scores[int(p["peer_id"])] = 0

	_phase = Phase.IDLE
	_round_index = 0
	_drawer_slot = -1
	_used_words = PackedStringArray()
	_history.clear()
	_correct_at.clear()
	_time_left = 0.0

	if _bank.total() == 0:
		push_error("词库是空的，检查 res://data/words/words.csv")


func start_round() -> void:
	if _players.size() < 2:
		_finish()
		return

	_round_index += 1
	_drawer_slot = _next_drawer_slot()
	_correct_at.clear()
	_round_rows.clear()
	_entry = {}

	var difficulty: int = _cfg.get("difficulty", 2)
	_candidates = _bank.pick(difficulty, CANDIDATE_COUNT, _used_words)
	if _candidates.is_empty():
		push_error("词库抽不出题，检查难度 %d 的可用词量" % difficulty)
		_finish()
		return

	_candidates.shuffle()
	_set_phase(Phase.CHOOSING, CHOOSE_SECONDS)
	candidates_offered.emit(_candidates)
	round_started.emit(_round_index)


func tick(delta: float) -> void:
	if not _is_authority():
		return
	if _phase == Phase.IDLE or _phase == Phase.FINISHED:
		return

	_time_left = maxf(0.0, _time_left - delta)
	phase_changed.emit(_phase, _time_left)

	if _time_left > 0.0:
		return

	# 时间到，按阶段决定下一步
	match _phase:
		Phase.CHOOSING:
			# 画手没选词，替他选第一个，别让整局卡住
			_choose_word(0)
		Phase.DRAWING:
			_end_round()
		Phase.ROUND_END:
			if _round_index >= int(_cfg.get("rounds", DEFAULT_ROUNDS)):
				_finish()
			else:
				start_round()


func on_player_input(peer_id: int, payload: PackedByteArray) -> void:
	if not _is_authority():
		return
	var msg := DrawGuessMessages.decode(payload)
	if msg.is_empty():
		return

	match int(msg["action"]):
		DrawGuessMessages.Action.PICK_WORD:
			if peer_id == get_drawer_peer_id() and _phase == Phase.CHOOSING:
				_choose_word(int(msg["index"]))

		DrawGuessMessages.Action.GUESS:
			if _phase == Phase.DRAWING and peer_id != get_drawer_peer_id():
				_evaluate_guess(peer_id, String(msg["text"]))

		DrawGuessMessages.Action.MARK_CORRECT:
			# 热座模式：画手代其他人点"猜对了"
			if _phase == Phase.DRAWING and peer_id == get_drawer_peer_id():
				_mark_correct(int(msg["peer_id"]))

		DrawGuessMessages.Action.STROKE:
			if _phase == Phase.DRAWING and peer_id == get_drawer_peer_id():
				var chunk: PackedByteArray = msg["payload"]
				if _allow_stroke(peer_id, chunk.size()):
					# 原样广播，权威端不需要解码再编码
					broadcast_requested.emit(payload)
					stroke_forwarded.emit(payload)

		DrawGuessMessages.Action.CLEAR:
			if _phase == Phase.DRAWING and peer_id == get_drawer_peer_id():
				broadcast_requested.emit(payload)
				stroke_forwarded.emit(payload)


func on_player_left(peer_id: int) -> void:
	var idx := _slot_of(peer_id)
	if idx < 0:
		return
	var was_drawer := idx == _drawer_slot
	_players.remove_at(idx)
	_scores.erase(peer_id)

	# 画手走了这一回合没法继续了，直接收掉，别让其他人干等
	if was_drawer and (_phase == Phase.CHOOSING or _phase == Phase.DRAWING):
		_drawer_slot = -1
		_end_round()
		return

	if _drawer_slot > idx:
		_drawer_slot -= 1
	if _players.size() < 2:
		_finish()


func on_player_disconnected(peer_id: int) -> void:
	# 断线不立刻踢人，允许重连。超时由各阶段倒计时兜底。
	pass


func on_player_reconnected(peer_id: int) -> void:
	# 重连的人需要补一份完整快照（含他自己的可见信息）。
	# 单机热座不需要处理，联网接入时由房间层调用 snapshot_for() 补发。
	pass


func is_finished() -> bool:
	return _phase == Phase.FINISHED


func get_results() -> Array:
	var rows: Array = []
	for peer_id in _scores:
		rows.append({"peer_id": peer_id, "score": _scores[peer_id]})
	rows.sort_custom(func(a, b): return int(a["score"]) > int(b["score"]))
	return rows


func get_replay_data() -> Dictionary:
	return {
		"game": ID,
		"rounds": _history.duplicate(true),
		"final_scores": get_results(),
	}


# ------------------------------------------------------------------ 查询接口（给 UI 和网络层用）

func get_phase() -> Phase:
	return _phase


## 提前结束当前等待（例如玩家点了"继续"按钮），
## 走的是和超时同一条路径，不另开一套状态流转。
func advance_now() -> void:
	if not _is_authority():
		return
	if _phase == Phase.ROUND_END or _phase == Phase.FINISHED:
		_time_left = 0.0
		tick(0.0)


func get_time_left() -> float:
	return _time_left


func get_round_index() -> int:
	return _round_index


func get_players() -> Array:
	return _players


func get_scores() -> Dictionary:
	return _scores.duplicate()


func get_drawer_peer_id() -> int:
	if _drawer_slot < 0 or _drawer_slot >= _players.size():
		return 0
	return int(_players[_drawer_slot]["peer_id"])


func is_drawer(peer_id: int) -> bool:
	return peer_id == get_drawer_peer_id()


func get_candidates() -> Array:
	return _candidates


## 谜底。**只有本回合结束后才对外给值**，回合进行中返回空串。
## 猜词者屏幕上永远不该出现这个词，除非本回合已经结算。
func get_revealed_word() -> String:
	if _phase == Phase.ROUND_END or _phase == Phase.FINISHED:
		return String(_entry.get("word", ""))
	return ""


## 画手看到的完整信息
func get_word_for(peer_id: int) -> String:
	if is_drawer(peer_id) and not _entry.is_empty():
		return String(_entry["word"])
	return get_revealed_word()


## 猜词者看到的提示：掩码 + 字数 + 类别
func get_hint_text() -> String:
	if _entry.is_empty():
		return ""
	var word := String(_entry["word"])
	var reveal_first := bool(_cfg.get("hints", true)) \
		and _time_left <= float(_cfg.get("round_seconds", DEFAULT_ROUND_SECONDS)) * 0.5
	# 下划线之间要留出明显间隙。只用单个空格的话，
	# 两个下划线仍然会连成一整条横线，玩家数不出这是几个字。
	var parts := PackedStringArray()
	for i in word.length():
		parts.append(word[i] if (i == 0 and reveal_first) else "_")
	var masked := "  ".join(parts)
	return "%s（%d 个字 · %s）" % [masked, word.length(), String(_entry.get("category", ""))]


func get_category() -> String:
	return String(_entry.get("category", ""))


func get_guessed_count() -> int:
	return _correct_at.size()


func get_guesser_total() -> int:
	return maxi(0, _players.size() - 1)


func has_guessed(peer_id: int) -> bool:
	return _correct_at.has(peer_id)


## 权威端的状态快照，交给网络层广播（联网接入时用）
func snapshot() -> Dictionary:
	return {
		"phase": _phase,
		"time_left": _time_left,
		"round_index": _round_index,
		"drawer": get_drawer_peer_id(),
		"scores": _scores.duplicate(),
		"guessed": _correct_at.keys(),
		"hint": get_hint_text(),
		"revealed": get_revealed_word(),
		"players": _players.duplicate(true),
	}


# ------------------------------------------------------------------ 内部逻辑

func _merge_defaults(cfg: Dictionary) -> Dictionary:
	var out := {}
	for item in get_config_schema():
		out[item["id"]] = item["default"]
	for key in cfg:
		out[key] = cfg[key]
	return out


func _is_authority() -> bool:
	# 不在场景树里时（单元测试、或直接被驱动）默认当权威端，
	# 否则 Node.multiplayer 取不到值，测试没法跑。
	if not is_inside_tree():
		return true
	var mp := multiplayer
	if mp == null or mp.multiplayer_peer == null:
		return true
	return mp.is_server()


func _set_phase(phase: Phase, seconds: float) -> void:
	_phase = phase
	_time_left = seconds
	phase_changed.emit(_phase, _time_left)


func _slot_of(peer_id: int) -> int:
	for i in _players.size():
		if int(_players[i]["peer_id"]) == peer_id:
			return i
	return -1


func _next_drawer_slot() -> int:
	if _players.is_empty():
		return -1
	var n := _players.size()
	for step in range(1, n + 1):
		var slot := posmod(_drawer_slot + step, n)
		if not _correct_at.has(int(_players[slot]["peer_id"])):
			return slot
	return posmod(_drawer_slot + 1, n)


func _choose_word(index: int) -> void:
	if _phase != Phase.CHOOSING:
		return
	if _candidates.is_empty():
		_finish()
		return
	_entry = _candidates[clampi(index, 0, _candidates.size() - 1)]
	_candidates.clear()
	_used_words.append(String(_entry["word"]))

	word_selected.emit(
		String(_entry["word"]),
		String(_entry.get("category", "")),
		int(_entry.get("difficulty", 1))
	)
	_set_phase(Phase.DRAWING, float(_cfg.get("round_seconds", DEFAULT_ROUND_SECONDS)))


func _evaluate_guess(peer_id: int, text: String) -> void:
	if _entry.is_empty() or has_guessed(peer_id):
		return
	if _bank.matches(_entry, text):
		_mark_correct(peer_id)
		guess_evaluated.emit(peer_id, text, true, false)
	else:
		var near := _bank.is_close(_entry, text, NEAR_THRESHOLD)
		guess_evaluated.emit(peer_id, text, false, near)


func _mark_correct(peer_id: int) -> void:
	if _entry.is_empty() or has_guessed(peer_id):
		return
	if peer_id == get_drawer_peer_id():
		return
	if _slot_of(peer_id) < 0:
		return

	_correct_at[peer_id] = _time_left
	someone_guessed.emit(peer_id, _time_left)

	# 所有人都猜对了就提前收尾，不用干等到超时
	if _correct_at.size() >= get_guesser_total():
		_end_round()


func _end_round() -> void:
	if _entry.is_empty():
		# 画手在选词阶段就跑了之类的情况，没有任何分数可算
		_round_rows.clear()
		round_settled.emit("", _round_rows)
		_set_phase(Phase.ROUND_END, ROUND_END_SECONDS)
		return

	var word := String(_entry["word"])
	var difficulty := int(_entry.get("difficulty", 1))
	var multiplier := float(WordBank.DIFFICULTY_MULTIPLIER.get(difficulty, 1.0))
	var drawer_id := get_drawer_peer_id()
	var drawer_points := 0
	var rows: Array = []

	for peer_id in _correct_at:
		var remaining := float(_correct_at[peer_id])
		var points := int(round((GUESS_BASE_POINTS + remaining * GUESS_TIME_FACTOR) * multiplier))
		_scores[peer_id] = int(_scores.get(peer_id, 0)) + points
		drawer_points += DRAWER_POINTS_PER_GUESSER
		rows.append({"peer_id": peer_id, "points": points, "remaining": remaining})

	var guessers := get_guesser_total()
	var all_guessed := guessers > 0 and _correct_at.size() >= guessers
	if all_guessed:
		drawer_points += DRAWER_ALL_GUESSED_BONUS
	if drawer_points > 0 and _slot_of(drawer_id) >= 0:
		_scores[drawer_id] = int(_scores.get(drawer_id, 0)) + drawer_points

	rows.sort_custom(func(a, b): return int(a["points"]) > int(b["points"]))
	_round_rows = rows

	_history.append({
		"round": _round_index,
		"drawer": drawer_id,
		"word": word,
		"category": String(_entry.get("category", "")),
		"all_guessed": all_guessed,
		"drawer_points": drawer_points,
		"rows": rows.duplicate(true),
	})

	round_settled.emit(word, rows)
	scores_changed.emit(get_scores())
	round_finished.emit(_round_index)
	_set_phase(Phase.ROUND_END, ROUND_END_SECONDS)


func _finish() -> void:
	_phase = Phase.FINISHED
	_time_left = 0.0
	phase_changed.emit(_phase, _time_left)
	game_finished.emit()


## 令牌桶限流。正常画画远低于上限，但能挡住恶意刷屏。
func _allow_stroke(peer_id: int, nbytes: int) -> bool:
	if nbytes <= 0:
		return false
	var now := float(Time.get_ticks_msec()) / 1000.0
	if not _stroke_budget.has(peer_id):
		_stroke_budget[peer_id] = {"tokens": STROKE_BURST, "last": now}
	var bucket: Dictionary = _stroke_budget[peer_id]
	var elapsed := now - float(bucket["last"])
	bucket["tokens"] = minf(STROKE_BURST, float(bucket["tokens"]) + elapsed * STROKE_BYTES_PER_SEC)
	bucket["last"] = now
	if float(bucket["tokens"]) < float(nbytes):
		return false
	bucket["tokens"] = float(bucket["tokens"]) - float(nbytes)
	return true
