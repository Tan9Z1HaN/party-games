extends SceneTree

## 把 icon.svg 按 Godot 实际渲染的样子导出成 PNG，用来肉眼确认图标。
##
## ThorVG 不支持的 SVG 特性会**静默渲染成空白**，而 icon.svg 是脚本生成的
## 字形轮廓——改完生成脚本总得看一眼。渲染结果是否为空由
## tools/tests/export_config.gd 自动盯着，这个脚本只负责让人眼看到图。
##
##   godot --path . --script res://tools/tests/icon_preview.gd -- --out=name
##
## 想换个名字存（比如同时对比几个候选）就加 --out=<名字>。

func _initialize() -> void:
	var out := "icon_preview"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.substr(6)
	var texture: Texture2D = load("res://icon.svg")
	if texture == null:
		print("FAILED 图标加载不了")
		quit(1)
		return
	var image := texture.get_image()
	print("icon %dx%d  format=%d" % [image.get_width(), image.get_height(),
		image.get_format()])
	image.save_png("user://%s.png" % out)
	print("图片写到 user://%s.png" % out)
	quit(0)
