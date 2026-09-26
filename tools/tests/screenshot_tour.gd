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
	print("环游中国截图完成")
	quit(0)


## steps > 0 时先让 AI 走几步，好看到有地、有等级、棋子散开的样子
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

	for i in steps:
		if table._rules.is_finished():
			break
		# 人和 AI 都让 AI 逻辑代打，只为把画面推到中局
		TourAi.act(table._rules, table._rules.current_player())
	table._refresh()
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
