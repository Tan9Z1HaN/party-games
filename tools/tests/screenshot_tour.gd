extends SceneTree

## 环游中国牌桌的截图工具。
##
##   godot --path . --script res://tools/tests/screenshot_tour.gd
##
## **不要加 --headless**：headless 没有渲染，截出来是空的。
##
## 这个游戏最大的界面风险是**竖屏塞不下 40 格**：每格只有 98 像素，
## 名字写不下就等于白做。所以先把这个棋盘渲出来用眼睛看，再往下做交互。
##
## 会存两张：开局（大家都还没地）和打了一会儿（有地、有等级、有棋子分布）。

const SIZES := [
	[1080, 1920, "base_9x16"],
	[1080, 2340, "phone_tall"],
]


func _initialize() -> void:
	_run()


func _run() -> void:
	for entry in SIZES:
		var size := Vector2i(int(entry[0]), int(entry[1]))
		var tag: String = entry[2]
		await _capture(size, tag, "start", 0)
		await _capture(size, tag, "midgame", 10)
		await _capture(size, tag, "result", -1)
	print("环游中国截图完成")
	quit(0)


## steps > 0 时先让 AI 走几步，好看到有地、有等级、棋子散开的样子；
## steps < 0 表示直接打到有人破产，用来看结算面板。
func _capture(size: Vector2i, tag: String, screen: String, steps: int) -> void:
	var sub := SubViewport.new()
	sub.size = size
	sub.disable_3d = true
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(sub)

	var table: Control = load("res://games/tour/main.tscn").instantiate()
	sub.add_child(table)
	await _settle()
	table.setup_solo(3)
	await _settle()

	# 规则对象在游戏层里，牌桌是纯视图（见 games/tour/main.gd 的说明）
	var rules: TourRules = table._game.rules()
	var guard := 0
	while guard < (4000 if steps < 0 else steps):
		guard += 1
		if rules.is_finished():
			break
		# 人和 AI 都让 AI 逻辑代打，只为把画面推到中局 / 残局
		TourAi.act(rules, rules.current_player())
	table._refresh()
	# 动画不等帧（不锁帧时一帧几毫秒）：直接摆到终值再拍
	table._end_card()
	table._hop.clear()
	table._board.clear_moving()
	table._board.set_dice_anim(-1.0)
	table._show_dice(table._dice_value)
	if table._result_layer != null:
		table._result_layer.modulate.a = 1.0
		table._result_layer.scale = Vector2.ONE
	await _settle()

	var image := sub.get_texture().get_image()
	var name := "%s_%s_%dx%d" % [tag, screen, size.x, size.y]
	var err := image.save_png("user://tour_%s.png" % name)
	print("  tour_%s  err=%d" % [name, err])

	sub.queue_free()
	await process_frame


func _settle() -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
