extends SceneTree

## 把同一批界面分别渲染进几个不同尺寸的 SubViewport，检查「屏幕显示不全」。
##
##   godot --path . --script res://tools/tests/screenshot_matrix.gd
##
## **不要加 --headless**：headless 没有渲染，截出来是空的。
##
## 为什么要专门做这个工具：窗口尺寸受制于运行它的那台机器（本机窗口
## 高度被压到 1415），光看一张截图分不清「布局写死了」还是「就是这台机器
## 窗口小」。SubViewport 能把任意尺寸塞进来，一次把所有比例都跑一遍。
##
## 图片落在 user://，文件名带尺寸，方便对着比例排查。

## 每项是 [宽, 高, 说明]。
##
## 注意：project.godot 用的是 canvas_items + expand，可见区域**永远不会小于**
## 1080x1920，只在某一个方向上变大。所以这里只列真实可能出现的形状——
## 比如「1080x1415 的矮窗口」是不可能出现的，矮窗口换来的是更宽的可见区域。
const SIZES := [
	[1080, 1920, "base_9x16"],
	[1080, 2160, "phone_18x9"],
	[1080, 2400, "phone_20x9"],
	[1465, 1920, "desktop_wide"],
	[2560, 1920, "tablet_wide"],
]


func _initialize() -> void:
	_run()


func _run() -> void:
	for entry in SIZES:
		var size := Vector2i(int(entry[0]), int(entry[1]))
		var tag: String = entry[2]
		await _capture(size, tag, "picker", func(_main): pass)
		await _capture(size, tag, "menu", func(main):
			main._on_game_selected("uno")
		)
		await _capture(size, tag, "table", func(main):
			main._on_game_selected("uno")
			main._on_solo_pressed()
		)
		# 再打几张牌，看看牌堆和手牌在"打到一半"时的样子
		await _capture(size, tag, "table_played", func(main):
			main._on_game_selected("uno")
			main._on_solo_pressed()
		, 90)
	print("尺寸矩阵截图完成")
	quit(0)


## 在一个指定尺寸的 SubViewport 里跑一遍应用，执行 setup 之后截图。
## frames：setup 之后额外等几帧。出牌动画有两段 tween，不等够会拍到半空中的牌。
func _capture(size: Vector2i, tag: String, screen: String, setup: Callable,
		frames := 0) -> void:
	var sub := SubViewport.new()
	sub.size = size
	sub.disable_3d = true
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(sub)

	var main: Control = load("res://app/main.tscn").instantiate()
	sub.add_child(main)
	await _settle()
	setup.call(main)
	for i in frames:
		await process_frame
	await _settle()
	await _settle()

	var image := sub.get_texture().get_image()
	var name := "%s_%s_%dx%d" % [tag, screen, size.x, size.y]
	var err := image.save_png("user://matrix_%s.png" % name)
	print("  %s  err=%d" % [name, err])

	sub.queue_free()
	await process_frame


func _settle() -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
