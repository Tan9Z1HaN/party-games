extends SceneTree

## UNO 牌桌的界面冒烟测试。
##
## 逻辑单测跑得再全，也测不出「界面在某个状态下崩了」这类问题。
## 这里实例化真的牌桌，然后**把引擎跑出来的每一个状态都渲染一遍**，
## 确认不会崩——包括长手牌、选色阶段、游戏结束。
##
##   godot --headless --path . --script res://games/uno/tests/smoke_scene.gd

var _passed := 0
var _failed := 0
var _scene


func _initialize() -> void:
	print("=== UNO 牌桌冒烟测试 ===")
	var packed = load("res://games/uno/main.tscn")
	_check("场景能加载", packed != null)
	if packed == null:
		_finish()
		return
	_scene = packed.instantiate()
	root.add_child(_scene)
	_run()


## 必须等一帧：_initialize 阶段场景树还没运转，add_child 不会触发 _ready。
func _run() -> void:
	await process_frame
	await process_frame

	_check("界面构建完成", _scene._cards_root != null and _scene._status_label != null)
	if _scene._cards_root == null:
		_finish()
		return

	_scene.setup_solo(2)
	await process_frame

	_test_initial_state()
	_test_fake_3d_pose()
	await _test_render_every_state()
	await _test_draw()
	_test_color_picker_pops()
	_test_networked_wiring()
	_finish()


func _test_initial_state() -> void:
	print("\n-- 开局状态 --")
	_check("发了 7 张手牌", _scene._hand_cards.size() == 7, "%d" % _scene._hand_cards.size())
	_check("每张手牌都有牌值", _scene._hand_cards[0].card >= 0)
	_check("弃牌堆顶有牌", _scene._pile_card.card >= 0)
	_check("牌堆是扣着的", not _scene._deck_card.face_up)
	_check("张数标签有内容", _scene._counts_label.text.length() > 0, _scene._counts_label.text)
	_check("状态行有内容", _scene._status_label.text.length() > 0, _scene._status_label.text)
	_check("颜色行有内容", _scene._color_label.text.length() > 0)
	# 起始牌恰好翻到变色牌时，规则上第一个玩家就要先定颜色，
	# 这时候面板本来就该是亮的——所以只能对"面板状态和规则一致"下断言。
	_check("选色面板的显示跟规则一致",
		_scene._color_picker.visible == (_scene._game._rules.phase()
			== UnoRules.Phase.CHOOSING_COLOR
			and _scene._game._rules.color_chooser() == 1))


## 手牌是平铺展开的：一张挨一张横着排，不带旋转也不带 3D 姿态。
## 伪 3D 只在「提起一张牌」的时候出现。
func _test_fake_3d_pose() -> void:
	print("\n-- 手牌平铺 / 提起才有伪 3D --")
	var cards = _scene._hand_cards
	var first = cards[0]
	var last = cards[cards.size() - 1]

	var flat := true
	var detail := ""
	for card in cards:
		if absf(card.rotation) > 0.0001 or absf(card.perspective_x) > 0.0001 \
				or absf(card.perspective_y) > 0.0001:
			flat = false
			detail = "rotation=%f x=%f y=%f" % [card.rotation,
				card.perspective_x, card.perspective_y]
	_check("手牌是平铺的（没有角度也没有 3D 姿态）", flat, detail)
	_check("手牌在同一条水平线上",
		is_equal_approx(first.position.y, last.position.y),
		"%f vs %f" % [first.position.y, last.position.y])
	_check("手牌从左到右依次排开", first.position.x < last.position.x,
		"%f vs %f" % [first.position.x, last.position.x])
	_check("右边的牌压在左边上面", int(cards[1].z_index) > int(first.z_index),
		"%d vs %d" % [cards[1].z_index, first.z_index])
	_check("每张牌都拿到了牌面贴图",
		_scene._pile_card.texture_ready() and _scene._deck_card.texture_ready()
			and first.texture_ready())

	# 提起最右边那张，并且是从它的右半边抓起来的
	var lifted_card = last
	lifted_card.set_grab(lifted_card.position + Vector2(40, 0))
	lifted_card.set_lifted(true, false)
	_check("提起来会向上位移",
		lifted_card.position.y < lifted_card._base_position.y,
		"%f vs %f" % [lifted_card.position.y, lifted_card._base_position.y])
	_check("提起来会放大", lifted_card.scale.x > first.scale.x,
		"%f vs %f" % [lifted_card.scale.x, first.scale.x])
	_check("提起来才出现 3D 姿态", absf(lifted_card.perspective_y) > 0.5,
		"y_rot=%f" % lifted_card.perspective_y)
	_check("抓右边就往右翻", lifted_card.perspective_y < 0.0,
		"y_rot=%f" % lifted_card.perspective_y)
	_check("提起的牌压在整手牌上面",
		int(lifted_card.z_index) > int(cards[cards.size() - 2].z_index),
		"%d vs %d" % [lifted_card.z_index, cards[cards.size() - 2].z_index])

	# 效果是自洽的：放回去就回到平铺
	lifted_card.set_lifted(false, false)
	_check("放回去之后又是平的",
		absf(lifted_card.perspective_y) < 0.0001
			and absf(lifted_card.rotation) < 0.0001,
		"y_rot=%f rotation=%f" % [lifted_card.perspective_y, lifted_card.rotation])


## 把引擎跑到结束，每一步都刷新一次界面。
## 这是「界面能不能渲染引擎产生的任何状态」的实测。
func _test_render_every_state() -> void:
	print("\n-- 渲染引擎跑出来的每个状态 --")
	var rules: UnoRules = _scene._game._rules
	var steps := 0
	var saw_choosing_color := false
	while not rules.is_finished() and steps < 3000:
		steps += 1
		_drive_once(rules)
		# 先让界面渲染这个状态，再往下推进——这才叫「渲染引擎产生的每个状态」
		_scene._sync_hand()
		_scene._refresh()
		if rules.phase() == UnoRules.Phase.CHOOSING_COLOR:
			saw_choosing_color = true
			rules.choose_color(rules.current_player(),
				UnoAi.choose_color(rules, rules.current_player()))
		if steps % 40 == 0:
			await process_frame

	# 循环是靠 await 让 _process 里的 AI 也参与推进的，
	# 退出前最后一步可能是 AI 走的，界面还没跟上，这里补一次同步。
	_scene._sync_hand()
	_scene._refresh()
	_check("整局能跑完", rules.is_finished(), "%d 步" % steps)
	# 这一局出不出选色阶段取决于洗牌，硬断言会随机翻车（踩过一次）。
	# 选色界面本身由 _test_color_picker_pops 确定性地覆盖。
	print("      （这一局出现过选色阶段：%s）" % ("是" if saw_choosing_color else "否"))
	_check("结束后状态行显示赢家", _scene._status_label.text.contains(
		_scene._name_of(rules.winner())), _scene._status_label.text)
	_check("结束后界面没崩", _scene._hand_cards.size() == rules.hand_count(1),
		"%d vs %d" % [_scene._hand_cards.size(), rules.hand_count(1)])
	# 「本机选色要弹面板」不在这里验：本机一整局都没摸到万能牌的话，
	# 这个状态压根不会出现，断言会随机翻车。改成下面确定性地摆一个局面。

	_test_long_hand_layout(rules)


## 摸牌。之前压根没有摸牌的入口——玩家点了一圈都动不了，
## 只能干看着「没摸牌就不能过」。
func _test_draw() -> void:
	print("\n-- 摸牌 --")
	# 先把上一步可能还在飞的那张牌等完，否则 _busy 挡着摸不了
	for i in 40:
		await process_frame
	_check("出牌动画跑完后不再忙碌", not _scene._busy)

	var rules: UnoRules = _scene._game._rules
	# 摆一个「轮到本机、桌面红 5、手里只有一张出不掉的蓝 9」的局面
	var discard: Array[int] = [UnoDeck.make(UnoDeck.C.RED, UnoDeck.F.N5)]
	rules._discard = discard
	rules._order = [1, 2, 3]
	rules._cursor = 0
	rules._direction = 1
	rules._phase = UnoRules.Phase.PLAYING
	rules._pending_draw = 0
	rules._pending_face = -1
	rules._drawn_this_turn = false
	rules._winner = 0
	rules._uno_flag = {}
	var hand: Array[int] = [UnoDeck.make(UnoDeck.C.BLUE, UnoDeck.F.N9)]
	rules._hands[1] = hand
	_scene._selected = -1
	_scene._sync_hand()
	_scene._layout()
	_scene._refresh()

	_check("牌堆的判定框认得出牌堆中心", _scene._hit_deck(_scene._deck_center))
	_check("手牌区不会被当成牌堆",
		not _scene._hit_deck(_scene._hand_cards[0].position),
		"hand=%s deck=%s" % [_scene._hand_cards[0].position, _scene._deck_center])

	var before := rules.hand_count(1)
	_scene._on_draw()
	_check("摸牌之后手牌多了一张", rules.hand_count(1) == before + 1,
		"%d -> %d" % [before, rules.hand_count(1)])
	_check("界面上的手牌也跟着多了",
		_scene._hand_cards.size() == before + 1,
		"%d" % _scene._hand_cards.size())
	_check("同一回合不能摸第二次",
		not bool(rules.draw_card(1).get("ok", false)))
	# 家规 auto_pass 开着：摸到出不掉的牌会直接过回合，那时提示语该是下家的
	if rules.current_player() == 1:
		_check("摸过之后提示改成出牌或过牌",
			_scene._status_label.text.contains("过牌"), _scene._status_label.text)
	else:
		print("      （摸到的那张出不掉，auto_pass 直接过回合了）")

	# 等飞牌动画跑完再往下走
	for i in 60:
		await process_frame
	_check("摸牌动画结束后恢复可操作", not _scene._busy)
	_check("摸到的那张牌露出来了", _scene._hand_cards[before].visible)


## 本机出万能牌 -> 进入选色阶段 -> 面板弹出来 -> 选完收回去。
func _test_color_picker_pops() -> void:
	print("\n-- 本机选色 --")
	var rules: UnoRules = _scene._game._rules
	# 直接摆一个「轮到本机、手里有万能牌、桌面是红 5」的局面
	rules._order = [1, 2, 3]
	rules._cursor = 0
	rules._direction = 1
	rules._phase = UnoRules.Phase.PLAYING
	rules._pending_draw = 0
	rules._pending_face = -1
	rules._drawn_this_turn = false
	rules._winner = 0
	rules._uno_flag = {}
	# 这些成员是 Array[int]，必须给带类型的数组，不能给数组字面量
	var discard: Array[int] = [UnoDeck.make(UnoDeck.C.RED, UnoDeck.F.N5)]
	rules._discard = discard
	rules._active_color = UnoDeck.C.RED
	var hand: Array[int] = [
		UnoDeck.make(UnoDeck.C.WILD, UnoDeck.F.WILD),
		UnoDeck.make(UnoDeck.C.RED, UnoDeck.F.N9),
	]
	rules._hands[1] = hand
	_scene._selected = -1
	_scene._sync_hand()
	_scene._refresh()

	_check("摆好之后轮到本机", rules.current_player() == 1,
		"%d" % rules.current_player())
	_check("这时候还不该弹选色面板", not _scene._color_picker.visible)

	_scene._try_play_hand_card(0)
	_check("出万能牌后进入选色阶段",
		rules.phase() == UnoRules.Phase.CHOOSING_COLOR, "%d" % rules.phase())
	_check("等着选色的是本机", rules.color_chooser() == 1)
	_check("选色面板弹出来了", _scene._color_picker.visible)

	_scene._on_color_chosen(UnoDeck.C.BLUE)
	_check("选完颜色面板收回去", not _scene._color_picker.visible)
	_check("颜色定成了蓝", rules.active_color() == UnoDeck.C.BLUE)


## 联机入口的接线。真的连网要靠 tools/tests/run_net_uno.ps1，
## 这里只确认「app.gd 调了 setup_networked 之后，牌桌和游戏对象接上了」——
## 少接一根线（比如忘了 bind_room）点什么都纹丝不动，而且不报错。
func _test_networked_wiring() -> void:
	print("\n-- 联机接线 --")
	var room := Room.new()
	root.add_child(room)
	var players: Array = [
		{"peer_id": 1, "name": "甲"},
		{"peer_id": 2, "name": "乙"},
	]
	_scene.setup_networked(room, players, {})

	_check("联机之后牌桌挂上了游戏对象", _scene._game != null)
	_check("游戏对象知道往哪个房间发操作",
		_scene._game != null and _scene._game._room == room)
	_check("还没开局时状态是空的",
		_scene._game != null and _scene._game.state().is_empty())
	# 客户端点了也没用：重发只能由房主发起，不然两边的牌对不上
	_check("客户端看不到重开一局的按钮", not _scene._again_button.visible)
	room.queue_free()


## 手牌很多时扇形要自己压缩间距，不能铺出屏幕。
## 这是布局里最容易翻车的一处，但它取决于摸牌运气——
## 所以直接摆一个 15 张的局面来测，而不是等它自然发生。
func _test_long_hand_layout(rules: UnoRules) -> void:
	print("\n-- 手牌很多时的布局 --")
	var big: Array[int] = []
	for i in 15:
		big.append(UnoDeck.make(UnoDeck.C.RED, i % 10))
	rules._hands[1] = big
	_scene._sync_hand()

	_check("15 张手牌都建出来了", _scene._hand_cards.size() == 15,
		"%d" % _scene._hand_cards.size())
	var left := 1.0e9
	var right := -1.0e9
	for card in _scene._hand_cards:
		left = minf(left, card.position.x - UnoCard2D.SIZE.x * 0.5)
		right = maxf(right, card.position.x + UnoCard2D.SIZE.x * 0.5)
	_check("没有铺出左边界", left >= 0.0, "left=%f" % left)
	_check("没有铺出右边界", right <= _scene.size.x, "right=%f 屏宽=%f" % [right, _scene.size.x])

	# 手牌压到最底下那排按钮上，玩家就点不到了（第一版就是这么翻车的）
	var bottom := -1.0e9
	for card in _scene._hand_cards:
		bottom = maxf(bottom, card.position.y
			+ card.scale.y * UnoCard2D.SIZE.y * 0.5)
	_check("手牌没有压到底部按钮上", bottom <= _scene.size.y - 110.0,
		"bottom=%f 屏高=%f" % [bottom, _scene.size.y])


func _drive_once(rules: UnoRules) -> void:
	var peer := rules.current_player()
	if rules.phase() == UnoRules.Phase.CHOOSING_COLOR:
		return      # 交给外层处理，界面才有机会渲染这个状态
	var card := UnoAi.choose_card(rules, peer)
	if card >= 0:
		rules.play_card(peer, card)
		return
	var drew := rules.draw_card(peer)
	if bool(drew.get("playable", false)):
		var again := UnoAi.choose_card(rules, peer)
		if again >= 0:
			rules.play_card(peer, again)
			return
	if rules.current_player() == peer:
		rules.pass_turn(peer)


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
