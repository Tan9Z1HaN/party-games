extends SceneTree

## 把 fake3d shader 在不同 y_rot / inset 下的样子排成一张对照图。
##
##   godot --path . --script res://tools/tests/shader_probe.gd
##
## 伪 3D 的顶点撑大倍数和透视缩放是耦合的，光看公式推不出「转 30 度到底
## 会不会被裁掉」。摆出来看最快。

const ROTS := [0.0, 10.0, 20.0, 30.0, 45.0, 60.0, 90.0, 135.0, 180.0]
const COL_STEP := 170.0
const ROW_STEP := 260.0
const MARGIN := Vector2(90, 130)

var _shader: Shader = preload("res://games/uno/ui/fake3d.gdshader")


func _initialize() -> void:
	_run()


func _run() -> void:
	await UnoCardArt.ensure_baked()
	var texture := UnoCardArt.texture_of(UnoDeck.make(UnoDeck.C.RED, 7), true)

	var sub := SubViewport.new()
	sub.size = Vector2i(int(MARGIN.x * 2 + COL_STEP * ROTS.size()),
		int(MARGIN.y * 2 + ROW_STEP * 2))
	sub.transparent_bg = false
	sub.disable_3d = true
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(sub)

	var layer := Node2D.new()
	sub.add_child(layer)

	# 两行：inset=0（保持尺寸）和 inset=1（缩进矩形内）
	for row in 2:
		var inset := float(row)
		for col in ROTS.size():
			var sprite := Sprite2D.new()
			sprite.texture = texture
			sprite.centered = true
			sprite.position = Vector2(MARGIN.x + COL_STEP * col,
				MARGIN.y + ROW_STEP * row)
			var mat := ShaderMaterial.new()
			mat.shader = _shader
			mat.set_shader_parameter("y_rot", ROTS[col])
			mat.set_shader_parameter("inset", inset)
			mat.set_shader_parameter("cull_back", false)
			sprite.material = mat
			layer.add_child(sprite)

	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw

	var image := sub.get_texture().get_image()
	image.save_png("user://shader_probe.png")
	print("shader 对照图：user://shader_probe.png  %dx%d" % [image.get_width(), image.get_height()])
	quit(0)
