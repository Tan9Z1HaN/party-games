extends SceneTree

## 把 icon.svg 按 Godot 实际渲染的样子导出成 PNG，用来肉眼确认图标。
##
## ThorVG 不支持的 SVG 特性会**静默渲染成空白**，而 icon.svg 是脚本生成的
## 字形轮廓——改完生成脚本总得看一眼。渲染结果是否为空由
## tools/tests/export_config.gd 自动盯着，这个脚本只负责让人眼看到图。
##
##   godot --path . --script res://tools/tests/icon_preview.gd

func _initialize() -> void:
	var texture: Texture2D = load("res://icon.svg")
	if texture == null:
		print("FAILED 图标加载不了")
		quit(1)
		return
	var image := texture.get_image()
	print("icon %dx%d  format=%d" % [image.get_width(), image.get_height(),
		image.get_format()])
	image.save_png("user://icon_preview.png")
	print("图片写到 user://icon_preview.png")
	quit(0)
