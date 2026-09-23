extends SceneTree

## 开发用：把关键界面逐张截图，用来做视觉检查。
##
## **不要加 --headless** —— headless 模式没有渲染，截出来是空的。
##
##   godot --path . --script res://tools/screenshot.gd --resolution 720x1280
##
## 截图落在 user:// 下，Windows 上是
##   %APPDATA%\Godot\app_userdata\PartyGames\
##
## 存在的意义：像「浅色文字压在浅色面板上读不出来」这种问题，
## 单测和冒烟测试全都是绿的，只有真的看一眼才发现得了。

var _scene


func _initialize() -> void:
	var packed = load("res://games/draw_guess/main.tscn")
	if packed == null:
		push_error("加载 main.tscn 失败")
		quit(1)
		return
	_scene = packed.instantiate()
	root.add_child(_scene)
	_run()


func _run() -> void:
	await _shot("01_setup")

	_scene._player_count.select(1)     # 4 人
	_scene._rounds_input.select(0)     # 1 回合，这样最后能走到最终排名页
	_scene._seconds_input.select(2)    # 80 秒
	_scene._start_game()
	await _shot("02_pass")

	_scene._awaiting_pass = false
	_scene._refresh()
	await _shot("03_choose")

	_scene._choose_box.get_child(0).pressed.emit()
	await _shot("04_draw")

	for peer_id in _scene._guesser_buttons.keys().duplicate():
		var button = _scene._guesser_buttons.get(peer_id)
		if is_instance_valid(button):
			button.pressed.emit()
	await _shot("05_result")

	_scene._game.advance_now()
	await _shot("06_final")

	print("截图完成")
	quit(0)


func _shot(label: String) -> void:
	# 等两帧让容器重新布局，再等一帧真正画完，否则会截到上一帧的样子
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw

	var image := root.get_texture().get_image()
	var path := "user://%s.png" % label
	var err := image.save_png(path)
	print("  %s  %dx%d  err=%d" % [label, image.get_width(), image.get_height(), err])
