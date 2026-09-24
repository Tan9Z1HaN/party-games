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
	_check("选色面板开局不显示", not _scene._color_picker.visible)


## 伪 3D 就靠这三样，得确认它真的被套上去了——
## 全是一堆 1.0 和 0.0 的话，牌看着就是平的。
func _test_fake_3d_pose() -> void:
	print("\n-- 伪 3D 姿态 --")
	var first = _scene._hand_cards[0]
	var last = _scene._hand_cards[_scene._hand_cards.size() - 1]
	_check("边上的牌有旋转", absf(first.rotation) > 0.001,
		"rotation=%f" % first.rotation)
	_check("边上的牌有错切", absf(first.skew) > 0.001, "skew=%f" % first.skew)
	_check("边上的牌纵向被压缩", first.scale.y < 1.0, "scale.y=%f" % first.scale.y)
	_check("两端的倾斜方向相反", signf(first.rotation) != signf(last.rotation),
		"%f vs %f" % [first.rotation, last.rotation])
	_check("中间的牌压在两端上面",
		int(_scene._hand_cards[3].z_index) > int(first.z_index),
		"%d vs %d" % [_scene._hand_cards[3].z_index, first.z_index])


## 把引擎跑到结束，每一步都刷新一次界面。
## 这是「界面能不能渲染引擎产生的任何状态」的实测。
func _test_render_every_state() -> void:
	print("\n-- 渲染引擎跑出来的每个状态 --")
	var rules: UnoRules = _scene._rules
	var steps := 0
	var saw_choosing_color := false
	var saw_local_color_picker := false
	while not rules.is_finished() and steps < 3000:
		steps += 1
		_drive_once(rules)
		# 先让界面渲染这个状态，再往下推进——这才叫「渲染引擎产生的每个状态」
		_scene._sync_hand()
		_scene._refresh()
		if rules.phase() == UnoRules.Phase.CHOOSING_COLOR:
			saw_choosing_color = true
			if rules.color_chooser() == 1:
				saw_local_color_picker = _scene._color_picker.visible
			rules.choose_color(rules.current_player(),
				UnoAi.choose_color(rules, rules.current_player()))
		if steps % 40 == 0:
			await process_frame

	_check("整局能跑完", rules.is_finished(), "%d 步" % steps)
	_check("过程中出现过选色阶段", saw_choosing_color)
	_check("轮到本机选颜色时会弹选色面板", saw_local_color_picker)
	_check("结束后状态行显示赢家", _scene._status_label.text.contains(
		_scene._name_of(rules.winner())), _scene._status_label.text)
	_check("结束后界面没崩", _scene._hand_cards.size() == rules.hand_count(1),
		"%d vs %d" % [_scene._hand_cards.size(), rules.hand_count(1)])

	_test_long_hand_layout(rules)


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
