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
		_scene._color_picker.visible == (_scene._rules.phase()
			== UnoRules.Phase.CHOOSING_COLOR
			and _scene._rules.color_chooser() == 1))


## 伪 3D 是 shader 里的透视投影，姿态就靠绕横轴/竖轴两个角度。
## 全是一堆 0 的话，牌看着就是平的。
func _test_fake_3d_pose() -> void:
	print("\n-- 伪 3D 姿态 --")
	var first = _scene._hand_cards[0]
	var last = _scene._hand_cards[_scene._hand_cards.size() - 1]
	_check("边上的牌有旋转", absf(first.rotation) > 0.001,
		"rotation=%f" % first.rotation)
	_check("边上的牌绕竖轴转过去了", absf(first.perspective_y) > 0.5,
		"y_rot=%f" % first.perspective_y)
	_check("两端的绕轴方向相反",
		signf(first.perspective_y) != signf(last.perspective_y),
		"%f vs %f" % [first.perspective_y, last.perspective_y])
	_check("整把牌有仰角", absf(first.perspective_x) > 0.5,
		"x_rot=%f" % first.perspective_x)
	# 超过 70 度这个投影会把牌拉成一条巨大的竖条，实测过
	_check("绕轴角度都在安全范围内",
		absf(first.perspective_y) < 70.0 and absf(last.perspective_y) < 70.0,
		"%f / %f" % [first.perspective_y, last.perspective_y])
	_check("中间的牌压在两端上面",
		int(_scene._hand_cards[3].z_index) > int(first.z_index),
		"%d vs %d" % [_scene._hand_cards[3].z_index, first.z_index])
	_check("每张牌都拿到了牌面贴图",
		_scene._pile_card.texture_ready() and _scene._deck_card.texture_ready()
			and first.texture_ready())


## 把引擎跑到结束，每一步都刷新一次界面。
## 这是「界面能不能渲染引擎产生的任何状态」的实测。
func _test_render_every_state() -> void:
	print("\n-- 渲染引擎跑出来的每个状态 --")
	var rules: UnoRules = _scene._rules
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
	_check("过程中出现过选色阶段", saw_choosing_color)
	_check("结束后状态行显示赢家", _scene._status_label.text.contains(
		_scene._name_of(rules.winner())), _scene._status_label.text)
	_check("结束后界面没崩", _scene._hand_cards.size() == rules.hand_count(1),
		"%d vs %d" % [_scene._hand_cards.size(), rules.hand_count(1)])
	# 「本机选色要弹面板」不在这里验：本机一整局都没摸到万能牌的话，
	# 这个状态压根不会出现，断言会随机翻车。改成下面确定性地摆一个局面。

	_test_long_hand_layout(rules)
	_test_color_picker_pops()


## 本机出万能牌 -> 进入选色阶段 -> 面板弹出来 -> 选完收回去。
func _test_color_picker_pops() -> void:
	print("\n-- 本机选色 --")
	var rules: UnoRules = _scene._rules
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
