extends SceneTree

## 环游中国的房间层与报文测试。
##
##   godot --headless --path . --script res://games/tour/tests/game_layer.gd
##
## 验的是联机那条路：房主跑规则、广播完整状态；客户端不跑规则，
## 只把收到的状态套上。最后一段是「一局打完，逐帧比对两端」——
## 两端状态对不对得上，只有把两边的记录摆在一起才看得出来。

var _passed := 0
var _failed := 0


func _initialize() -> void:
	print("=== 环游中国 · 房间层测试 ===")
	_test_messages()
	_test_authority_flow()
	_test_client_mirror()
	_test_player_left()
	_test_full_game_matches()
	_finish()


func _test_messages() -> void:
	print("\n-- 报文 --")
	var cases := [
		[TourMessages.encode_roll(), TourMessages.Action.ROLL],
		[TourMessages.encode_buy(), TourMessages.Action.BUY],
		[TourMessages.encode_upgrade(), TourMessages.Action.UPGRADE],
		[TourMessages.encode_decline(), TourMessages.Action.DECLINE],
		[TourMessages.encode_pay_fine(), TourMessages.Action.PAY_FINE],
		[TourMessages.encode_tax_flat(), TourMessages.Action.TAX_FLAT],
		[TourMessages.encode_tax_percent(), TourMessages.Action.TAX_PERCENT],
	]
	for pair in cases:
		var data: PackedByteArray = pair[0]
		_check("动作 %d 能原样往返" % int(pair[1]),
			int(TourMessages.decode(data).get("action", 0)) == int(pair[1]))
		_check("动作 %d 只占一个字节" % int(pair[1]), data.size() == 1,
			"%d 字节" % data.size())
	_check("空报文解成空字典", TourMessages.decode(PackedByteArray()).is_empty())
	_check("未知动作解成空字典",
		TourMessages.decode(PackedByteArray([200])).is_empty())
	_check("零号动作也当非法",
		TourMessages.decode(PackedByteArray([0])).is_empty())


func _players(n := 3) -> Array:
	var names := ["甲", "乙", "丙", "丁"]
	var out: Array = []
	for i in n:
		out.append({"peer_id": i + 1, "name": names[i]})
	return out


func _test_authority_flow() -> void:
	print("\n-- 房主（权威端）--")
	var game := TourGame.new()
	game.setup(_players(), {})
	game.start_round()

	var state := game.state()
	_check("开局给了三个人", state.get("players", []).size() == 3,
		str(state.get("players", []).size()))
	_check("起始资金是常量值",
		int(state["players"][0]["cash"]) == TourRules.START_CASH,
		"%d" % int(state["players"][0]["cash"]))
	_check("轮到 1 号", int(state.get("current", 0)) == 1)
	_check("快照里带着过路费表（界面点格子要看）",
		state.has("rent") and state.has("owner") and state.has("level"))

	# 合法的掷骰会推进局面
	var before := str(state.get("log", ""))
	game.on_player_input(1, TourMessages.encode_roll())
	_check("掷骰之后状态变了", str(game.state().get("log", "")) != before,
		game.state().get("log", ""))

	# 没轮到的人发指令：必须被拒，状态一点都不许动
	var snapshot_before := str(game.snapshot())
	game.on_player_input(3, TourMessages.encode_roll())
	_check("没轮到的人发指令不生效", str(game.snapshot()) == snapshot_before)

	# 完全不存在的 peer
	game.on_player_input(99, TourMessages.encode_roll())
	_check("不存在的玩家发指令不崩", str(game.snapshot()) == snapshot_before)

	# 乱码报文
	game.on_player_input(1, PackedByteArray([200]))
	_check("乱码报文被丢掉", str(game.snapshot()) == snapshot_before)
	game.free()


func _test_client_mirror() -> void:
	print("\n-- 客户端镜像 --")
	var host := TourGame.new()
	host.setup(_players(), {})
	host.start_round()

	var client := TourGame.new()
	client.setup(_players(), {})
	_check("客户端手里没有规则对象", client.rules() == null)
	_check("客户端还没收到快照时状态是空的", client.state().is_empty())

	client._apply_snapshot_data(host.snapshot())
	var cs := client.state()
	_check("客户端的状态和房主一致",
		int(cs.get("current", 0)) == int(host.state().get("current", 0))
			and int(cs.get("round", 0)) == int(host.state().get("round", 0)),
		"%s vs %s" % [cs.get("current"), host.state().get("current")])
	_check("客户端拿到了完整的地产表",
		cs.get("owner") is Dictionary and cs.get("rent") is Dictionary)

	# 客户端不该自己跑规则
	client.on_player_input(1, TourMessages.encode_roll())
	_check("客户端的 on_player_input 不生效（它不是权威端）",
		client.state().get("owner", {}).is_empty()
			== host.state().get("owner", {}).is_empty())
	host.free()
	client.free()


func _test_player_left() -> void:
	print("\n-- 有人退房 --")
	var game := TourGame.new()
	game.setup(_players(), {})
	game.start_round()
	game.on_player_left(2)
	var state := game.state()
	# **退房的人留在列表里，但标成出局**：地释放了、回合跳过了，
	# 但他的名字和资产还看得见——玩家需要知道"刚才那个人怎么没了"。
	# 从列表里抹掉的话，界面上会莫名其妙少一个人。
	_check("退房的人还留在列表里（标成出局）",
		state.get("players", []).size() == 3,
		"%d" % state.get("players", []).size())
	var out_row := {}
	for row in state.get("players", []):
		if int(row["peer_id"]) == 2:
			out_row = row
	_check("他被标成出局", bool(out_row.get("out", false)), str(out_row))
	_check("他还活着的人数只剩 2", int(state.get("alive", 0)) == 2,
		"%d" % int(state.get("alive", 0)))
	_check("回合没停在不存在的人身上",
		int(state.get("current", 0)) != 2, "%d" % int(state.get("current", 0)))
	game.free()


## 房主真打完一局，每一步都把快照喂给客户端，最后比对两边。
func _test_full_game_matches() -> void:
	print("\n-- 一局打完，两端比对 --")
	var host := TourGame.new()
	host.setup(_players(), {})
	host.start_round()

	# 客户端扮演「乙」：房主是「甲」，它自己那份状态不走网络
	var client := TourGame.new()
	client.setup([
		{"peer_id": 2, "name": "乙"},
		{"peer_id": 1, "name": "甲"},
		{"peer_id": 3, "name": "丙"},
	], {})

	var mismatch := ""
	var steps := 0
	while not host.is_finished() and steps < 20000:
		steps += 1
		var actor := host.rules().current_player()
		# 用 AI 代所有人做决定，只为把局面推到底
		TourAi.act(host.rules(), actor)
		# 网络：房主把完整状态发过去
		client._apply_snapshot_data(host.snapshot())

		var hs := host.snapshot()
		var cs := client.state()
		for key in ["current", "phase", "decision", "pending_cell", "round",
				"alive", "finished", "card_seq"]:
			if str(hs.get(key)) != str(cs.get(key)):
				mismatch = "%s: 房主=%s 客户端=%s" % [key, hs.get(key), cs.get(key)]
				break
		if not mismatch.is_empty():
			break

	_check("这一局能打完", host.is_finished(), "%d 步" % steps)
	_check("整局过程中两端状态始终一致", mismatch.is_empty(), mismatch)
	_check("客户端的排名和房主一致",
		str(client.get_results()) == str(host.get_results()),
		str(client.get_results()))
	print("      打了 %d 步，赢家 %d 号" % [steps, host.rules().winner()])
	host.free()
	client.free()


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
	else:
		_failed += 1
		print("  [FAIL] ", label, "   ", detail)


func _finish() -> void:
	print("\n=== 通过 %d，失败 %d ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
