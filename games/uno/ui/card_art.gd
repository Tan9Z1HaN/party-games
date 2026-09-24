class_name UnoCardArt
extends RefCounted

## UNO 牌面贴图的运行时缓存。
##
## **为什么要烘贴图**：伪 3D 是在 shader 里做透视除法（见 fake3d.gdshader），
## 而 shader 的 `TEXTURE` 必须真的是一张贴图。Node2D 用 `_draw()` 画出来的
## 没有「一张贴图」——文字走字体图集、多边形走白点图，透视数学套不上去。
## 所以把 UnoCardPainter 画的结果先渲染进 SubViewport，再取出来当贴图用。
##
## **为什么不在仓库里放 PNG**：牌面是画出来的，不是美术给的。留成代码就
## 能改完配色直接看效果，不用「改脚本 -> 重跑烘焙 -> 提交 55 张图」。
## 代价是第一次进牌桌要多烘几帧，只在开局付一次。
##
## headless 下没有渲染，退回成纯色占位贴图：测试只验逻辑，不看像素。

## 单张牌的贴图尺寸，跟 UnoCardPainter.SIZE 一致。
const CARD := Vector2i(148, 216)
## 网格里的单元格。留 6 像素空边，免得生成 mipmap 时把邻居的像素吸过来。
const PAD := 6
const CELL := Vector2i(CARD.x + PAD * 2, CARD.y + PAD * 2)
const COLS := 8

static var _cache := {}
static var _baked := false


## 走一遍烘焙。已经烘过就直接返回。调用方 `await` 它。
static func ensure_baked() -> void:
	if _baked:
		return
	_baked = true

	var entries := entries()
	if DisplayServer.get_name() == "headless":
		for entry in entries:
			_cache[entry[0]] = _placeholder(int(entry[1]), bool(entry[2]))
		return

	var rows := int(ceil(float(entries.size()) / float(COLS)))
	var sub := SubViewport.new()
	sub.size = Vector2i(CELL.x * COLS, CELL.y * rows)
	sub.transparent_bg = true
	sub.disable_3d = true
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	Engine.get_main_loop().root.add_child(sub)

	var layer := Node2D.new()
	sub.add_child(layer)
	for i in entries.size():
		var painter := UnoCardPainter.new()
		painter.set_card(int(entries[i][1]), bool(entries[i][2]))
		var cell_origin := Vector2(float(CELL.x * (i % COLS)),
			float(CELL.y * int(i / COLS)))
		painter.position = cell_origin + Vector2(CELL) * 0.5
		layer.add_child(painter)

	await Engine.get_main_loop().process_frame
	await Engine.get_main_loop().process_frame
	await RenderingServer.frame_post_draw

	var atlas := sub.get_texture().get_image()
	for i in entries.size():
		var rect := Rect2i(CELL.x * (i % COLS) + PAD, CELL.y * int(i / COLS) + PAD,
			CARD.x, CARD.y)
		_cache[entries[i][0]] = _to_texture(atlas.get_region(rect))

	sub.queue_free()


## 取一张牌的贴图。没烘过就返回 null，调用方自己兜底。
static func texture_of(card: int, face_up: bool) -> Texture2D:
	var tex: Texture2D = _cache.get(key_of(card, face_up))
	if tex != null:
		return tex
	if not _baked:
		return _placeholder(card, face_up)
	return null


## 缓存键。跟 card_painter.gd 的画法一一对应。
static func key_of(card: int, face_up: bool) -> String:
	if not face_up or card < 0:
		return "back"
	var color := UnoDeck.color_of(card)
	if color == UnoDeck.C.WILD:
		return "wild" if UnoDeck.face_of(card) == UnoDeck.F.WILD else "wild4"
	var base: String = ["red", "yellow", "green", "blue"][color]
	match UnoDeck.face_of(card):
		UnoDeck.F.SKIP: return base + "_skip"
		UnoDeck.F.REVERSE: return base + "_reverse"
		UnoDeck.F.DRAW2: return base + "_draw2"
	return "%s_%d" % [base, UnoDeck.face_of(card)]


static func entries() -> Array:
	var out: Array = []
	var colors := ["red", "yellow", "green", "blue"]
	for color in [UnoDeck.C.RED, UnoDeck.C.YELLOW, UnoDeck.C.GREEN, UnoDeck.C.BLUE]:
		for face in range(0, UnoDeck.F.N9 + 1):
			out.append(["%s_%d" % [colors[color], face],
				UnoDeck.make(color, face), true])
		for face in [UnoDeck.F.SKIP, UnoDeck.F.REVERSE, UnoDeck.F.DRAW2]:
			out.append([UnoCardArt.key_of(UnoDeck.make(color, face), true),
				UnoDeck.make(color, face), true])
	out.append(["wild", UnoDeck.make(UnoDeck.C.WILD, UnoDeck.F.WILD), true])
	out.append(["wild4", UnoDeck.make(UnoDeck.C.WILD, UnoDeck.F.WILD4), true])
	out.append(["back", -1, false])
	return out


## 从 SubViewport 抠出来的图是共享缓冲区的，必须先复制一份再改；
## fix_alpha_edges 是为了补掉透明边上的黑边，mipmap 会把黑边放大成灰圈。
static func _to_texture(region: Image) -> ImageTexture:
	var cell: Image = region.duplicate()
	cell.fix_alpha_edges()
	cell.generate_mipmaps()
	return ImageTexture.create_from_image(cell)


static func _placeholder(card: int, face_up: bool) -> ImageTexture:
	var color := Color(0.35, 0.35, 0.4)
	if face_up and card >= 0:
		color = UnoCardPainter.COLOR_FILL.get(UnoDeck.color_of(card), color)
	var image := Image.create(CARD.x, CARD.y, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)
