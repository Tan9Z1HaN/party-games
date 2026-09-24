extends SceneTree

## 把应用几个主要界面截图存到 user://，用来做视觉检查。
##
## **不要加 --headless** —— headless 没有渲染，截出来是空的。
##
##   godot --path . --script res://tools/tests/screenshot_app.gd --resolution 1080x1920
##
## 起因：玩家反馈「屏幕显示不全」，但测试全绿、启动也没报错——
## 这类问题只有看图才发现得了。

var _main


func _initialize() -> void:
	_main = load("res://app/main.tscn").instantiate()
	root.add_child(_main)
	_run()


func _run() -> void:
	await _settle()
	await _shot("app_01_picker")

	_main._on_game_selected("uno")
	await _settle()
	await _shot("app_02_menu_uno")

	_main._on_solo_pressed()
	await _settle()
	await _settle()
	await _shot("app_03_uno_table")

	_main._show_picker()
	_main._on_game_selected("draw_guess")
	await _settle()
	await _shot("app_04_menu_draw_guess")

	print("截图完成")
	quit(0)


func _settle() -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw


func _shot(label: String) -> void:
	var image := root.get_texture().get_image()
	var path := "user://%s.png" % label
	var err := image.save_png(path)
	print("  %s  %dx%d  err=%d" % [label, image.get_width(), image.get_height(), err])
