extends SceneTree

## 把 UnoCardArt 烘出来的贴图逐个查一遍：有没有、多大、长什么样。
##
##   godot --path . --script res://tools/tests/art_probe.gd

func _initialize() -> void:
	_run()


func _run() -> void:
	await UnoCardArt.ensure_baked()
	var missing := 0
	for entry in UnoCardArt.entries():
		var key: String = entry[0]
		var tex := UnoCardArt.texture_of(int(entry[1]), bool(entry[2]))
		if tex == null:
			missing += 1
			print("  [MISS] ", key)
		else:
			print("  [ok]   %-16s %dx%d" % [key, tex.get_width(), tex.get_height()])
	print("缺失 %d 张" % missing)

	for pair in [["back", -1, false],
			["red_7", UnoDeck.make(UnoDeck.C.RED, 7), true],
			["wild4", UnoDeck.make(UnoDeck.C.WILD, UnoDeck.F.WILD4), true]]:
		var tex := UnoCardArt.texture_of(int(pair[1]), bool(pair[2]))
		if tex != null:
			tex.get_image().save_png("user://probe_%s.png" % pair[0])
	quit(0)
