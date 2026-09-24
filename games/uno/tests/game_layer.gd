extends SceneTree

## UNO 房间层（UnoGame）与报文（UnoMessages）的测试。
##
##   godot --headless --path . --script res://games/uno/tests/game_layer.gd
##
## 这里验的是**联机那条路**：房主跑规则、把公开状态广播出去、把每个人的
## 手牌单发出去；客户端不该跑规则，只把收到的套上去。
## 两端状态对不对得上，只有把两边的记录摆在一起才看得出来——
## 所以最后一段是「一局打完，逐帧比对两端」。

var _passed := 0
var _failed := 0


func _initialize() -> void:
	print("=== UNO 房间层测试 ===")
	_test_messages()
	_test_authority_flow()
	_test_client_mirror()
	_test_remove_player()
	_test_full_game_matches()
	_finish()


# ------------------------------------------------------------------ 报文

func _test_messages() -> void:
	print("\n-- 报文编解码 --")

	var play := UnoMessages.decode(UnoMessages.encode_play(58, 3))
	_check("出牌能原样解出来",
		int(play.get("card", -1)) == 58 and int(play.get("color", -1)) == 3,
		str(play))
	var no_color := UnoMessages.decode(UnoMessages.encode_play(58, -1))
	_check("没指定颜色时是哨兵值",
		int(no_color.get("color", 0)) == UnoMessages.NO_COLOR, str(no_color))

	_check("摸牌能解出来",
		int(UnoMessages.decode(UnoMessages.encode_draw()).get("action", 0))
			== UnoMessages.Action.DRAW)
	_check("过牌能解出来",
		int(UnoMessages.decode(UnoMessages.encode_pass()).get("action", 0))
			== UnoMessages.Action.PASS)
	_check("喊 UNO 能解出来",
		int(UnoMessages.decode(UnoMessages.encode_say_uno()).get("action", 0))
			== UnoMessages.Action.SAY_UNO)
	_check("选颜色能解出来",
		int(UnoMessages.decode(UnoMessages.encode_choose_color(2)).get("color", -1)) == 2)

	var played := UnoMessages.decode(UnoMessages.encode_played(7, 21))
	_check("出牌广播里有是谁出的",
		int(played.get("peer_id", 0)) == 7 and int(played.get("card", 0)) == 21,
		str(played))
	_check("摸牌广播里有是谁摸的",
		int(UnoMessages.decode(UnoMessages.encode_drew(9, 2)).get("count", 0)) == 2)

	var hand: Array = [UnoDeck.make(UnoDeck.C.RED, 3), UnoDeck.make(UnoDeck.C.WILD, UnoDeck.F.WILD4)]
	var decoded := UnoMessages.decode(UnoMessages.encode_hand(hand))
	_check("手牌能原样解出来",
		Array(decoded.get("cards", [])) == hand, str(decoded.get("cards", [])))

	# 中文要能过网络。按字节截断而不是按字符截断才不会切出半个汉字。
	var text := "小红 出了 红7，颜色定成了蓝"
	var logged := UnoMessages.decode(UnoMessages.encode_log(text))
	_check("日志文本原样往返", String(logged.get("text", "")) == text,
		String(logged.get("text", "")))
	var rejected := UnoMessages.decode(UnoMessages.encode_reject("还没轮到你"))
	_check("拒绝原因原样往返",
		String(rejected.get("text", "")) == "还没轮到你", str(rejected))

	# 脏数据一律解成空字典，调用方丢掉就行，不能崩
	_check("空报文解成空字典", UnoMessages.decode(PackedByteArray()).is_empty())
	_check("未知动作解成空字典", UnoMessages.decode(PackedByteArray([200])).is_empty())
	_check("出牌报文缺字节也不崩",
		UnoMessages.decode(PackedByteArray([UnoMessages.Action.PLAY])).is_empty())
	_check("手牌数量对不上时解成空字典",
		UnoMessages.decode(PackedByteArray([UnoMessages.Action.SET_HAND, 9, 1])).is_empty())



# ------------------------------------------------------------------ 权威端

func _three_players() -> Array:
	return [
		{"peer_id": 1, "name": "甲"},
		{"peer_id": 2, "name": "乙"},
		{"peer_id": 3, "name": "丙"},
	]


func _test_authority_flow() -> void:
	print("\n-- 房主（权威端）--")
	var game := UnoGame.new()
	game.setup(_three_players(), {})
	game.start_round()

	var s := game.state()
	_check("开局后自己的手牌是 7 张",
		Array(s.get("my_hand", [])).size() == 7,
		"%d" % Array(s.get("my_hand", [])).size())
	_check("公开状态里有每个人剩几张",
		Array(s.get("players", [])).size() == 3
			and int(Array(s.get("players", []))[0]["count"]) == 7)
	_check("桌面上有起始牌", int(s.get("top_card", -1)) >= 0)
	_check("快照里不含任何人的手牌", not game.snapshot().has("my_hand"))

	# 轮到谁就给谁发意图。这样做不依赖洗牌运气，一定是合法的。
	var actor := int(s.get("current", 0))
	var hand := game._rules.hand_of(actor)
	var playable := -1
	for card in hand:
		if game._rules.can_play(actor, card):
			playable = card
			break

	if playable >= 0:
		var before := game._rules.hand_count(actor)
		game.on_player_input(actor, UnoMessages.encode_play(playable, -1))
		# 万能牌会先停在选色阶段，那时牌还没落地
		if game._rules.phase() == UnoRules.Phase.CHOOSING_COLOR:
			_check("出万能牌要先选颜色",
				game._rules.color_chooser() == actor)
			game.on_player_input(actor, UnoMessages.encode_choose_color(UnoDeck.C.BLUE))
			_check("选完颜色后颜色变了",
				game._rules.active_color() == UnoDeck.C.BLUE)
		_check("出牌之后手牌少了一张",
			game._rules.hand_count(actor) == before - 1,
			"%d -> %d" % [before, game._rules.hand_count(actor)])
	else:
		print("      （起手出不了牌，改测摸牌）")
		game.on_player_input(actor, UnoMessages.encode_draw())
		_check("摸牌之后手牌多了一张", game._rules.hand_count(actor) > 0)

	# 不该轮到的人出牌：必须被拒，而且状态一点都不能动
	# 注意要拿**当前**该谁，出牌之后回合已经换人了
	var now_current := game._rules.current_player()
	var other := 1
	for row in _three_players():
		if int(row["peer_id"]) != now_current:
			other = int(row["peer_id"])
			break
	var snapshot_before := game.snapshot()
	var logs: Array = []
	game.event_log.connect(func(t): logs.append(t))
	game.on_player_input(other, UnoMessages.encode_draw())
	_check("没轮到的人摸牌会被拒并给出理由",
		logs.size() > 0 and String(logs[0]).contains("不能这么做"), str(logs))
	_check("被拒之后公开状态没变",
		game.snapshot().get("top_card") == snapshot_before.get("top_card")
			and game.snapshot().get("current") == snapshot_before.get("current"))

	game.free()


# ------------------------------------------------------------------ 客户端

func _test_client_mirror() -> void:
	print("\n-- 客户端镜像 --")
	var host := UnoGame.new()
	host.setup(_three_players(), {})
	host.start_round()

	var client := UnoGame.new()
	client.setup(_three_players(), {})
	_check("客户端手里没有规则对象", client._rules == null)

	client._apply_snapshot_data(host.snapshot())
	var mine := host._rules.hand_of(1)
	client._apply_remote_message_data(UnoMessages.encode_hand(mine))

	var cs := client.state()
	_check("客户端的公开状态跟主机一致",
		int(cs.get("top_card", -1)) == host._rules.top_card()
			and int(cs.get("current", 0)) == host._rules.current_player(),
		"top=%s vs %s" % [cs.get("top_card"), host._rules.top_card()])
	_check("客户端拿到的就是单发给它的那份手牌",
		Array(cs.get("my_hand", [])) == mine, str(cs.get("my_hand", [])))

	# 广播来的动画事件要能转成界面用的信号
	var events: Array = []
	client.event_played.connect(func(peer_id, card): events.append([peer_id, card]))
	client._apply_remote_message_data(UnoMessages.encode_played(2, 58))
	_check("客户端能收到出牌事件",
		events.size() == 1 and int(events[0][0]) == 2 and int(events[0][1]) == 58,
		str(events))

	host.free()
	client.free()


func _test_remove_player() -> void:
	print("\n-- 有人离场 --")
	var game := UnoGame.new()
	game.setup(_three_players(), {})
	game.start_round()

	# 把回合轮到第 2 个人身上，再让他离场
	game._rules._cursor = game._rules._order.find(2)
	game.on_player_left(2)

	var s := game.state()
	var ids: Array = []
	for row in Array(s.get("players", [])):
		ids.append(int(row["peer_id"]))
	_check("离场的人从玩家列表里没了", not ids.has(2), str(ids))
	_check("回合没有停在一个不存在的人身上",
		int(s.get("current", 0)) != 2, "%d" % int(s.get("current", 0)))
	_check("剩下的人还在", ids.size() == 2, str(ids))
	game.free()


# ------------------------------------------------------------------ 整局比对

## 让房主真打完一局，每一步都把广播和快照喂给一个客户端，
## 最后比对两边的公开状态。这是防「房主显示对了、客户端显示错了」的关键。
func _test_full_game_matches() -> void:
	print("\n-- 一局打完，两端比对 --")
	var host := UnoGame.new()
	host.setup(_three_players(), {})
	host.start_round()

	# 把房主想发出去的东西收下来，模拟网络
	var broadcast: Array = []
	var unicast: Array = []
	host.broadcast_requested.connect(func(p): broadcast.append(p))
	host.to_player_requested.connect(func(pid, p): unicast.append([pid, p]))

	# 客户端扮演「乙」。房主是「甲」，而房主自己那份手牌不走网络
	# （本机直接读规则），所以镜像端必须是另一个人，否则永远收不到单发。
	var mirror_peer := 2
	var client := UnoGame.new()
	client.setup([
		{"peer_id": 2, "name": "乙"},
		{"peer_id": 1, "name": "甲"},
		{"peer_id": 3, "name": "丙"},
	], {})

	var mismatch := ""
	var steps := 0
	var stalled := 0
	var last_signature := ""
	while not host.is_finished() and steps < 4000:
		steps += 1
		var actor := host._rules.current_player()
		if host._rules.phase() == UnoRules.Phase.CHOOSING_COLOR:
			# 注意这里要挑一个合法颜色。直接拿 active_color() 会踩坑：
			# 万能牌待定的那一刻它就是 WILD(=4)，而合法颜色只有 0~3，
			# 于是每步都被拒、整局卡死——这个死循环正是靠这段测试抓出来的。
			host.on_player_input(actor,
				UnoMessages.encode_choose_color(UnoAi.choose_color(host._rules, actor)))
		else:
			var card := -1
			for c in host._rules.hand_of(actor):
				if host._rules.can_play(actor, c):
					card = c
					break
			if card >= 0:
				host.on_player_input(actor, UnoMessages.encode_play(card, -1))
			else:
				host.on_player_input(actor, UnoMessages.encode_draw())

		# 卡住检测：连着几步状态一点没动就说明有动作一直被拒，直接报出来，
		# 别让测试干跑到 4000 步才发现。
		var hs_now := host.snapshot()
		var signature := "%s|%s|%s|%s" % [hs_now.get("top_card"),
			hs_now.get("current"), hs_now.get("pending_draw"),
			hs_now.get("color_chooser")]
		if signature == last_signature:
			stalled += 1
		else:
			stalled = 0
			last_signature = signature
		if stalled > 12:
			break

		# 网络：先单发手牌，再广播，最后一份快照
		for entry in unicast:
			if int(entry[0]) == mirror_peer:
				client._apply_remote_message_data(entry[1])
		for payload in broadcast:
			client._apply_remote_message_data(payload)
		client._apply_snapshot_data(host.snapshot())
		unicast.clear()
		broadcast.clear()

		var hs := host.snapshot()
		var cs := client.state()
		for key in ["top_card", "active_color", "direction", "current",
				"color_chooser", "pending_draw", "winner", "finished"]:
			if hs.get(key) != cs.get(key):
				mismatch = "%s: 主机=%s 客户端=%s" % [key, hs.get(key), cs.get(key)]
				break
		if not mismatch.is_empty():
			break

	_check("这一局能打完", host.is_finished(), "%d 步" % steps)
	_check("客户端的手牌张数跟主机记录一致",
		Array(client.state().get("my_hand", [])).size()
			== host._rules.hand_count(mirror_peer),
		"%d vs %d" % [Array(client.state().get("my_hand", [])).size(),
			host._rules.hand_count(mirror_peer)])
	_check("整局过程中两端公开状态始终一致", mismatch.is_empty(), mismatch)
	_check("赢家两边一致",
		int(client.state().get("winner", 0)) == host._rules.winner())

	host.free()
	client.free()


# ------------------------------------------------------------------ 收尾

func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  [OK]   ", label)
	else:
		_failed += 1
		print("  [FAIL] ", label, "  ", detail)


func _finish() -> void:
	print("\n=== 通过 %d，失败 %d ===" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)
