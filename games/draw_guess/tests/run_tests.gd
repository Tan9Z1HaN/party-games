extends SceneTree

## 你画我猜的逻辑测试。运行方式：
##   godot --headless --path . --script res://games/draw_guess/tests/run_tests.gd
## 全部通过时退出码为 0。

var _passed := 0
var _failed := 0
var _forwarded: Array = []
var _fatal_messages: Array = []
var _snapshot_rows: Array = []
var _snapshot_word := ""


func _initialize() -> void:
	print("=== 你画我猜测试 ===")
	_test_word_bank()
	_test_normalize()
	_test_levenshtein()
	_test_synonyms()
	_test_messages()
	_test_game_flow()
	_test_hint_reveal()
	_test_stroke_authority()
	_test_timeouts()
	_test_drawer_leaves()
	_test_missing_word_bank()
	_test_drawer_rotation()
	_test_two_players()
	_test_client_snapshot()
	_finish()


# ---------------------------------------------------------------- 词库

func _test_word_bank() -> void:
	print("\n-- 词库 --")
	var bank := WordBank.load_default()
	_check("能加载", bank.total() > 0)
	_check("词库规模够用", bank.total() >= 700, "得到 %d" % bank.total())
	_check("简单档 >= 200", bank.count_of(1) >= 200, "%d" % bank.count_of(1))
	_check("中等档 >= 200", bank.count_of(2) >= 200, "%d" % bank.count_of(2))
	_check("困难档 >= 150", bank.count_of(3) >= 150, "%d" % bank.count_of(3))

	# 手写词库最容易出的问题就是重复，重复词会让同一局抽到两次
	var all := bank.all_words()
	var unique := {}
	for word in all:
		unique[word] = true
	_check("词库没有重复词", unique.size() == all.size(),
		"%d/%d" % [unique.size(), all.size()])

	var picked := bank.pick(1, 3, PackedStringArray())
	_check("抽满 3 个", picked.size() == 3, "%d" % picked.size())
	var seen := {}
	for e in picked:
		seen[e["word"]] = true
	_check("抽出的词不重复", seen.size() == picked.size())

	var banned := PackedStringArray([String(picked[0]["word"])])
	var again := bank.pick(1, 5, banned)
	var clean := true
	for e in again:
		if String(e["word"]) == String(banned[0]):
			clean = false
	_check("排除已用词", clean)

	var over := bank.pick(1, 999, PackedStringArray())
	_check("要得比库存多也不崩", over.size() > 0 and over.size() <= bank.total(),
		"要 999 拿到 %d" % over.size())


func _test_normalize() -> void:
	print("\n-- 文本规范化 --")
	_check("全角转半角", WordBank.normalize("ＡＢＣ") == "abc", WordBank.normalize("ＡＢＣ"))
	_check("去空格与标点", WordBank.normalize("自 行 车。") == "自行车", WordBank.normalize("自 行 车。"))
	_check("去英文标点", WordBank.normalize("hello, world!") == "helloworld", WordBank.normalize("hello, world!"))
	_check("统一小写", WordBank.normalize("AbC") == "abc")
	_check("空串", WordBank.normalize("   ") == "")


func _test_levenshtein() -> void:
	print("\n-- 编辑距离 --")
	_check("相同为 0", WordBank.levenshtein("abc", "abc") == 0)
	_check("多一个字符", WordBank.levenshtein("abc", "abcd") == 1)
	_check("中文差一字", WordBank.levenshtein("自行车", "自行画") == 1)
	_check("空串", WordBank.levenshtein("", "abc") == 3)
	_check("对称", WordBank.levenshtein("kitten", "sitting") == WordBank.levenshtein("sitting", "kitten"))


func _test_synonyms() -> void:
	print("\n-- 同义词与接近提示 --")
	var bank := WordBank.load_default()
	var bike := bank.find_by_word("自行车")
	_check("能按词查到", not bike.is_empty())
	_check("精确匹配", bank.matches(bike, "自行车"))
	_check("同义词一", bank.matches(bike, "单车"))
	_check("同义词二", bank.matches(bike, "脚踏车"))
	_check("带空格标点也匹配", bank.matches(bike, " 自行车！"))
	_check("错误答案不匹配", not bank.matches(bike, "摩托车"))
	_check("空猜词不匹配", not bank.matches(bike, ""))

	var ice := bank.find_by_word("冰淇淋")
	_check("不同词不同义", bank.matches(ice, "雪糕") and not bank.matches(ice, "冰棍"))

	_check("接近提示", bank.is_close(bike, "自行画", 1))
	_check("差太远不提示", not bank.is_close(bike, "飞机", 1))
	_check("长度差太多不提示", not bank.is_close(bike, "车", 1))

	# 单机、或者房主自己当画手时，答案是"本机发给本机"的。
	# 那条路径曾经把 _entry 覆盖成只有 word/category/difficulty 的字典，
	# 于是 matches() 去读 entry["synonyms"] 抛错——表现是"同义词猜对了也不算"，
	# 而且只在上面这两种情况下复现，联网对战里反倒看不出来。
	var game := DrawGuessGame.new()
	game._entry = bike
	game._apply_set_word("自行车", "交通", 1)
	_check("本机发答案不会冲掉词库那条记录", game._entry.has("synonyms"))
	_check("同义词照样能匹配", bank.matches(game._entry, "单车"))
	game.free()


# ---------------------------------------------------------------- 报文

func _test_messages() -> void:
	print("\n-- 小游戏报文 --")
	var m := DrawGuessMessages.decode(DrawGuessMessages.encode_pick_word(2))
	_check("选词", int(m.get("action", 0)) == DrawGuessMessages.Action.PICK_WORD and int(m.get("index", -1)) == 2)

	m = DrawGuessMessages.decode(DrawGuessMessages.encode_guess("自行车"))
	_check("猜词（中文）", String(m.get("text", "")) == "自行车", str(m))

	m = DrawGuessMessages.decode(DrawGuessMessages.encode_guess("bike"))
	_check("猜词（英文）", String(m.get("text", "")) == "bike")

	m = DrawGuessMessages.decode(DrawGuessMessages.encode_mark_correct(33))
	_check("标记猜对", int(m.get("peer_id", -1)) == 33)

	var chunk := StrokeCodec.encode_chunk(5, StrokeCodec.FLAG_BEGIN, 3, 1,
		PackedVector2Array([Vector2(10, 20), Vector2(30, 40)]))
	m = DrawGuessMessages.decode(DrawGuessMessages.encode_stroke(chunk))
	_check("笔迹原样透传", m.get("payload", PackedByteArray()) == chunk)

	_check("清空报文", int(DrawGuessMessages.decode(DrawGuessMessages.encode_clear()).get("action", 0)) == DrawGuessMessages.Action.CLEAR)
	_check("空数据", DrawGuessMessages.decode(PackedByteArray()).is_empty())
	_check("未知动作", DrawGuessMessages.decode(PackedByteArray([99, 1, 2])).is_empty())
	_check("截断的猜词", DrawGuessMessages.decode(PackedByteArray([DrawGuessMessages.Action.GUESS, 0])).is_empty())
	_check("截断的标记", DrawGuessMessages.decode(PackedByteArray([DrawGuessMessages.Action.MARK_CORRECT, 0])).is_empty())

	# 超长中文不能按字节切开，否则解码出乱码
	var long_text := "甲".repeat(200)
	m = DrawGuessMessages.decode(DrawGuessMessages.encode_guess(long_text))
	var got := String(m.get("text", ""))
	_check("超长被按字符截断", got.length() == DrawGuessMessages.MAX_GUESS_CHARS, "得到 %d 字" % got.length())
	_check("截断后没有乱码", got == "甲".repeat(DrawGuessMessages.MAX_GUESS_CHARS))


# ---------------------------------------------------------------- 完整一局

func _players() -> Array:
	return [
		{"peer_id": 11, "name": "甲"},
		{"peer_id": 22, "name": "乙"},
		{"peer_id": 33, "name": "丙"},
		{"peer_id": 44, "name": "丁"},
	]


func _new_game(cfg: Dictionary = {}) -> DrawGuessGame:
	var game := DrawGuessGame.new()
	var merged := {"rounds": 1, "round_seconds": 60, "difficulty": 1, "hints": true}
	for k in cfg:
		merged[k] = cfg[k]
	game.setup(_players(), merged)
	return game


func _test_game_flow() -> void:
	print("\n-- 完整一回合 --")
	var game := _new_game()
	_check("初始待机", game.get_phase() == DrawGuessGame.Phase.IDLE)

	game.start_round()
	_check("进入选词", game.get_phase() == DrawGuessGame.Phase.CHOOSING)
	_check("候选三个", game.get_candidates().size() == 3, "%d" % game.get_candidates().size())

	var drawer := game.get_drawer_peer_id()
	_check("指定了画手", drawer != 0)
	_check("所有人都 0 分", game.get_scores().values().all(func(v): return int(v) == 0))

	game.on_player_input(drawer, DrawGuessMessages.encode_pick_word(0))
	_check("进入作画", game.get_phase() == DrawGuessGame.Phase.DRAWING)

	var word := game.get_word_for(drawer)
	_check("画手看得到答案", not word.is_empty())
	_check("回合中答案不公开", game.get_revealed_word() == "")

	var guessers: Array = []
	for p in _players():
		if int(p["peer_id"]) != drawer:
			guessers.append(int(p["peer_id"]))
	var somebody: int = guessers[0]

	_check("猜词者看不到答案", game.get_word_for(somebody) == "")

	# 画手不能自己猜对
	game.on_player_input(drawer, DrawGuessMessages.encode_guess(word))
	_check("画手不能记分", not game.has_guessed(drawer))

	# 错误答案不记分
	game.on_player_input(somebody, DrawGuessMessages.encode_guess("这肯定不是答案"))
	_check("错误答案不记分", not game.has_guessed(somebody))

	# 重复猜对只算一次
	game.on_player_input(somebody, DrawGuessMessages.encode_guess(word))
	_check("猜对了", game.has_guessed(somebody))
	game.on_player_input(somebody, DrawGuessMessages.encode_guess(word))
	_check("重复猜对不重复计数", game.get_guessed_count() == 1, "%d" % game.get_guessed_count())

	for g in guessers:
		game.on_player_input(g, DrawGuessMessages.encode_guess(word))
	_check("全员猜对", game.get_guessed_count() == 3, "%d" % game.get_guessed_count())
	_check("全员猜对立即结算", game.get_phase() == DrawGuessGame.Phase.ROUND_END)
	_check("结算后公开答案", game.get_revealed_word() == word)

	var scores := game.get_scores()
	var guessers_scored := true
	for g in guessers:
		if int(scores.get(g, 0)) <= 0:
			guessers_scored = false
	_check("猜对者都有分", guessers_scored)
	_check("画手有分", int(scores.get(drawer, 0)) > 0, "%d" % int(scores.get(drawer, 0)))

	var results := game.get_results()
	_check("结果 4 人", results.size() == 4)
	_check("结果按分排序", int(results[0]["score"]) >= int(results[3]["score"]))

	game.tick(100.0)
	_check("回合跑满后结束", game.is_finished())
	_check("回放记录了 1 回合", game.get_replay_data()["rounds"].size() == 1)

	game.free()


func _test_hint_reveal() -> void:
	print("\n-- 提示揭示 --")
	var game := _new_game({"round_seconds": 60})
	game.start_round()
	var drawer := game.get_drawer_peer_id()
	game.on_player_input(drawer, DrawGuessMessages.encode_pick_word(0))
	var word := game.get_word_for(drawer)

	var early := game.get_hint_text()
	_check("前半段全是掩码", early.find(word.substr(0, 1)) == -1, early)
	_check("提示带上字数与类别", early.contains("个字") and early.contains("（"))

	game.tick(31.0)
	var late := game.get_hint_text()
	_check("过半后揭示首字", late.begins_with(word.substr(0, 1)), late)
	game.free()


func _test_stroke_authority() -> void:
	print("\n-- 笔迹转发权限 --")
	_forwarded.clear()
	var game := _new_game()
	game.stroke_forwarded.connect(func(_payload): _forwarded.append(_payload))
	game.start_round()
	var drawer := game.get_drawer_peer_id()
	game.on_player_input(drawer, DrawGuessMessages.encode_pick_word(0))

	var chunk := StrokeCodec.encode_chunk(1, StrokeCodec.FLAG_BEGIN, 0, 1,
		PackedVector2Array([Vector2(100, 100)]))
	var msg := DrawGuessMessages.encode_stroke(chunk)

	var somebody := 0
	for p in _players():
		if int(p["peer_id"]) != drawer:
			somebody = int(p["peer_id"])
			break

	game.on_player_input(somebody, msg)
	_check("非画手的笔迹被丢弃", _forwarded.is_empty(), "%d" % _forwarded.size())

	game.on_player_input(drawer, msg)
	_check("画手的笔迹被转发", _forwarded.size() == 1, "%d" % _forwarded.size())

	# 选词阶段的笔迹不该被接受
	_forwarded.clear()
	var game2 := _new_game()
	game2.stroke_forwarded.connect(func(_payload): _forwarded.append(_payload))
	game2.start_round()
	game2.on_player_input(game2.get_drawer_peer_id(), msg)
	_check("选词阶段不接受笔迹", _forwarded.is_empty())

	game.free()
	game2.free()


func _test_timeouts() -> void:
	print("\n-- 超时兜底 --")
	var game := _new_game({"rounds": 2, "round_seconds": 30})
	game.start_round()
	_check("选词阶段", game.get_phase() == DrawGuessGame.Phase.CHOOSING)

	game.tick(999.0)
	_check("选词超时替他选", game.get_phase() == DrawGuessGame.Phase.DRAWING)

	game.tick(999.0)
	_check("作画超时自动收尾", game.get_phase() == DrawGuessGame.Phase.ROUND_END)

	game.tick(999.0)
	_check("进入第二回合", game.get_phase() == DrawGuessGame.Phase.CHOOSING)
	_check("回合序号递增", game.get_round_index() == 2, "%d" % game.get_round_index())

	game.tick(999.0)
	game.tick(999.0)
	game.tick(999.0)
	_check("两回合后结束", game.is_finished())
	game.free()


func _test_drawer_leaves() -> void:
	print("\n-- 画手中途离开 --")
	var game := _new_game({"rounds": 3})
	game.start_round()
	var drawer := game.get_drawer_peer_id()
	game.on_player_input(drawer, DrawGuessMessages.encode_pick_word(0))
	_check("作画中", game.get_phase() == DrawGuessGame.Phase.DRAWING)

	game.on_player_left(drawer)
	_check("画手离开立即收尾", game.get_phase() == DrawGuessGame.Phase.ROUND_END)
	_check("离开者被移除", game.get_players().size() == 3)

	# 不能卡死：继续走下去
	game.tick(999.0)
	_check("能继续下一回合", game.get_phase() == DrawGuessGame.Phase.CHOOSING)

	# 掉到只剩一个人就该结束
	game.on_player_left(int(game.get_players()[0]["peer_id"]))
	game.on_player_left(int(game.get_players()[0]["peer_id"]))
	_check("人数不足即结束", game.is_finished())
	game.free()


# ---------------------------------------------------------------- 致命错误

func _test_missing_word_bank() -> void:
	print("\n-- 词库读不到时必须报错，不能静默结束 --")
	var game := DrawGuessGame.new()
	_fatal_messages.clear()
	game.fatal_error.connect(func(message): _fatal_messages.append(message))

	game.setup(_players(), {"word_bank_path": "res://data/words/__does_not_exist__.txt"})
	_check("setup 阶段就报错", _fatal_messages.size() == 1, "%d 条" % _fatal_messages.size())
	if not _fatal_messages.is_empty():
		var message := String(_fatal_messages[0])
		_check("错误里给出了具体路径", message.contains("__does_not_exist__"), message)
		_check("错误里提示了 include_filter", message.contains("include_filter"), message)

	# 就算硬走到 start_round，也只能报错 + 结束，不能装作没事发生
	_fatal_messages.clear()
	game.start_round()
	_check("抽不出题也报错", not _fatal_messages.is_empty())
	_check("没有进入回合", game.get_phase() == DrawGuessGame.Phase.FINISHED)

	game.free()


# ---------------------------------------------------------------- 画手轮换

func _test_drawer_rotation() -> void:
	print("\n-- 画手轮换 --")
	# 这条是回归测试：选下一轮画手的函数里曾经混进了「跳过已经猜对的人」，
	# 那是选猜词者才该有的规则。两人局里后果是永远同一个人在画。
	var game := _new_game({"rounds": 4, "round_seconds": 5})
	game.start_round()

	var order: Array = []
	for i in 4:
		var drawer := game.get_drawer_peer_id()
		order.append(drawer)
		# 推进一个完整回合：选词 -> 作画超时 -> 结算超时
		game.on_player_input(drawer, DrawGuessMessages.encode_pick_word(0))
		game.tick(999.0)
		game.tick(999.0)

	var unique := {}
	for peer_id in order:
		unique[peer_id] = true
	_check("四回合轮出四个不同的画手", unique.size() == 4, str(order))

	# 两人局最容易暴露：猜对的人下一轮必须能轮到自己画
	var duo := DrawGuessGame.new()
	duo.setup([
		{"peer_id": 1, "name": "甲"},
		{"peer_id": 2, "name": "乙"},
	], {"rounds": 4, "round_seconds": 60, "difficulty": 1, "hints": true})
	duo.start_round()
	var first: int = duo.get_drawer_peer_id()
	duo.on_player_input(first, DrawGuessMessages.encode_pick_word(0))
	var word: String = duo.get_word_for(first)
	duo.on_player_input(2 if first == 1 else 1, DrawGuessMessages.encode_guess(word))
	duo.tick(999.0)
	duo.tick(999.0)
	_check("两人局里画手会换人", duo.get_drawer_peer_id() != first,
		"一直是 %d" % first)
	duo.free()

	game.free()


## 两人局。下限从 3 改成 2 之后，这里钉住"两个人真的能玩完一回合"——
## 大厅按 min_players 放人进来，规则这边要是其实玩不了，症状是
## 开局即结束，而那种问题在编辑器里点不出来（得真的凑两个人）。
func _test_two_players() -> void:
	print("\n-- 两人局 --")
	_check("声明的最少人数是 2",
		int(DrawGuessGame.new().get_meta_info()["min_players"]) == 2)

	var duo := DrawGuessGame.new()
	duo.setup([
		{"peer_id": 1, "name": "甲"},
		{"peer_id": 2, "name": "乙"},
	], {"rounds": 1, "round_seconds": 60, "difficulty": 1, "hints": true})
	duo.start_round()
	_check("两人也能开局，没有立刻结束",
		duo.get_phase() == DrawGuessGame.Phase.CHOOSING, "%d" % duo.get_phase())

	var drawer: int = duo.get_drawer_peer_id()
	var guesser: int = 2 if drawer == 1 else 1
	duo.on_player_input(drawer, DrawGuessMessages.encode_pick_word(0))
	_check("选完词进入作画", duo.get_phase() == DrawGuessGame.Phase.DRAWING)

	# 两个人时"猜词者"只有一个：他一猜对就该直接进结算
	duo.on_player_input(guesser, DrawGuessMessages.encode_guess(duo.get_word_for(drawer)))
	_check("唯一的猜词者猜对后本回合立刻收尾",
		duo.get_phase() == DrawGuessGame.Phase.ROUND_END, "%d" % duo.get_phase())
	_check("猜对的人拿到分", int(duo.get_scores().get(guesser, 0)) > 0,
		str(duo.get_scores()))
	_check("画手也拿到分", int(duo.get_scores().get(drawer, 0)) > 0,
		str(duo.get_scores()))
	duo.free()


# ---------------------------------------------------------------- 客户端快照

func _test_client_snapshot() -> void:
	print("\n-- 客户端快照 --")
	# 回归测试：apply_snapshot 里结算行曾经硬编码成空数组，
	# 客户端结果页永远显示「没有人猜对」。
	# 走 _apply_snapshot_data 而不是 apply_snapshot，
	# 因为后者开头的权威端守卫会让没有 peer 的测试环境直接返回。
	var game := DrawGuessGame.new()
	_snapshot_rows = []
	_snapshot_word = ""
	# 注意：GDScript 的 lambda 按值捕获**局部变量**，所以这里只能写成员变量。
	# 写成局部变量的话，lambda 里赋值改的是它自己的副本，外面的看不到。
	game.round_settled.connect(func(word, rows):
		_snapshot_word = word
		_snapshot_rows = rows)

	game._apply_snapshot_data({
		"phase": DrawGuessGame.Phase.DRAWING,
		"time_left": 30.0,
		"round_index": 1,
		"drawer": 11,
		"scores": {11: 100, 22: 260},
		"guessed": [],
		"hint": "太_（2 个字 · 自然）",
		"revealed": "",
		"rows": [],
	})
	# 断言直接读 _remote_* 字段：对应的 getter 在客户端才走这条分支，
	# 而测试环境没有 multiplayer peer，_is_authority() 恒为真。
	_check("作画阶段不结算", _snapshot_rows.is_empty())
	_check("提示记录来自快照", game._remote_hint.contains("2 个字"), game._remote_hint)
	_check("画手记录来自快照", game._remote_drawer == 11, "%d" % game._remote_drawer)

	var rows := [{"peer_id": 22, "points": 260, "remaining": 30.0}]
	game._apply_snapshot_data({
		"phase": DrawGuessGame.Phase.ROUND_END,
		"time_left": 7.0,
		"round_index": 1,
		"drawer": 11,
		"scores": {11: 150, 22: 260},
		"guessed": [22],
		"hint": "",
		"revealed": "太阳",
		"rows": rows,
	})
	_check("切到结算会发一次结算事件", _snapshot_rows.size() == 1, "%d 行" % _snapshot_rows.size())
	if not _snapshot_rows.is_empty():
		_check("得分来自快照", int(_snapshot_rows[0]["points"]) == 260, str(_snapshot_rows[0]))
	_check("公开答案记录来自快照", game._remote_revealed == "太阳", game._remote_revealed)
	_check("公开答案随事件带出", _snapshot_word == "太阳", _snapshot_word)
	_check("已猜对名单来自快照", game.has_guessed(22))
	_check("分数来自快照", int(game.get_scores().get(22, 0)) == 260)

	game.free()


# ---------------------------------------------------------------- 工具

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
