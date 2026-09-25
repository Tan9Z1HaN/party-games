extends SceneTree

## 把开屏的收场动画按时间抓成几张图，用来肉眼确认节奏对不对。
##
##   godot --path . --script res://tools/tests/splash_frames.gd
##
## **不要加 --headless**：headless 没有渲染，截出来是空的。
##
## 动画本身没法用一张静态图检查，所以这里绕开 _show_splash 自带的时间轴，
## 手动放收场，然后按墙钟时间抓关键帧。

var _main: Control
var _last := 0


func _initialize() -> void:
	_main = load("res://app/main.tscn").instantiate()
	root.add_child(_main)
	_run()


func _run() -> void:
	await process_frame
	# 先让默认的开屏流程收掉，再手动摆一个"刚淡入完"的状态
	_main.dismiss_splash(true)
	_main._show_splash()
	if _main._splash_tween != null and _main._splash_tween.is_valid():
		_main._splash_tween.kill()
	_main._splash.modulate.a = 1.0
	_main._reset_splash()
	await _settle()
	await _shot("splash_0_full")

	_last = Time.get_ticks_msec()
	_main._play_splash_outro()
	await _shot_after(0.33, "splash_1_image_gone")
	await _shot_after(0.22, "splash_2_only_ju")
	await _shot_after(0.42, "splash_3_ju_moved")
	await _shot_after(0.55, "splash_4_wordmark")
	print("开屏分镜完成")
	quit(0)


## 距上一张过了多少秒之后再截下一张。
func _shot_after(seconds: float, label: String) -> void:
	var until := _last + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await process_frame
	_last = Time.get_ticks_msec()
	await _settle()
	await _shot(label)


func _settle() -> void:
	await process_frame
	await RenderingServer.frame_post_draw


func _shot(label: String) -> void:
	var image := root.get_texture().get_image()
	var err := image.save_png("user://%s.png" % label)
	print("  %s  %dx%d  err=%d" % [label, image.get_width(), image.get_height(), err])
