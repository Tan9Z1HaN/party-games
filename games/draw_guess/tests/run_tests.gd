extends SceneTree

## 你画我猜的逻辑测试。运行方式：
##   godot --headless --path . --script res://games/draw_guess/tests/run_tests.gd
## 全部通过时退出码为 0。

var _passed := 0
var _failed := 0
var _forwarded: Array = []
var _fatal_messages: Array = []


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
	_finish()


# ---------------------------------------------------------------- 词库

func _test_word_bank() -> void:
	print("\n-- 词库 --")
	var bank := WordBank.load_default()
	_check("能加载", bank.total() > 0)
	_check("总数 200", bank.total() == 200, "得到 %d" % bank.total())
	_check("简单档 >= 60", bank.count_of(1) >= 60, "%d" % bank.count_of(1))
	_check("中等档 >= 50", bank.count_of(2) >= 50, "%d" % bank.count_of(2))
	_check("困难档 >= 50", bank.count_of(3) >= 50, "%d" % bank.count_of(3))

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
	_check("要得比库存多也不崩", over.size() > 0 and over.size() <= 200)


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
