extends SceneTree

## headless 测试入口。运行方式：
##   godot --headless --path . --script res://drawing/tests/run_tests.gd
## 全部通过时退出码为 0，有失败时为 1。

var _passed := 0
var _failed := 0

## 编解码用的测试颜色，随便挑一个不会和默认值撞的
const _TEST_COLOR := Color(0.2, 0.4, 0.6)


func _initialize() -> void:
	print("=== 绘制引擎测试 ===")
	_test_codec_roundtrip()
	_test_codec_boundaries()
	_test_codec_clamp()
	_test_codec_garbage()
	_test_codec_batch()
	_test_board_roundtrip()
	_test_board_clear()
	_test_quantization()
	_test_palette()
	_test_uri()
	_finish()


# ---------------------------------------------------------------- 编解码

func _test_codec_roundtrip() -> void:
	print("\n-- 笔迹编解码往返 --")
	for n in [1, 2, 3, 17, 64, 200]:
		var pts := _make_points(n, 0)
		var chunk := StrokeCodec.encode_chunk(7, StrokeCodec.FLAG_BEGIN, _TEST_COLOR, 2, pts)
		var d := StrokeCodec.decode_chunk(chunk)
		_check("n=%d 能解码" % n, not d.is_empty())
		if d.is_empty():
			continue
		var back: PackedVector2Array = d["points"]
		_check("n=%d 点数一致" % n, back.size() == n, "得到 %d" % back.size())
		_check("n=%d 坐标一致" % n, _points_equal(pts, back))
		var meta_ok: bool = int(d["stroke_id"]) == 7 and int(d["width_q"]) == 2 \
			and (d["color"] as Color).is_equal_approx(_TEST_COLOR)
		_check("n=%d 元数据一致" % n, meta_ok, str(d.get("color", null)))


func _test_codec_boundaries() -> void:
	print("\n-- 边界坐标 --")
	for corner in [Vector2(0, 0), Vector2(4095, 4095), Vector2(0, 4095), Vector2(4095, 0)]:
		var pts := PackedVector2Array([corner])
		var d := StrokeCodec.decode_chunk(
			StrokeCodec.encode_chunk(1, StrokeCodec.FLAG_BEGIN | StrokeCodec.FLAG_END, _TEST_COLOR, 1, pts))
		var back: PackedVector2Array = d["points"]
		_check("角点 %s 往返一致" % str(corner), back.size() == 1 and back[0] == corner)

	# 贴着边界的小步长也应精确还原
	var near := PackedVector2Array([
		Vector2(4090, 4090), Vector2(4095, 4095), Vector2(4090, 4095), Vector2(4095, 4090),
	])
	var d2 := StrokeCodec.decode_chunk(
		StrokeCodec.encode_chunk(2, StrokeCodec.FLAG_BEGIN, _TEST_COLOR, 1, near))
	_check("边界小步长往返一致", _points_equal(near, d2["points"]))


func _test_codec_clamp() -> void:
	print("\n-- 超大步长（防御性夹取）--")
	# 相邻点跨度 4000，远超 i8 能表示的范围。
	# DrawBoard 会插值避免走到这一步，但编解码本身不能崩，也不能越界。
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(4000, 4000)])
	var d := StrokeCodec.decode_chunk(
		StrokeCodec.encode_chunk(1, StrokeCodec.FLAG_BEGIN, _TEST_COLOR, 1, pts))
	var back: PackedVector2Array = d["points"]
	_check("超大步长不崩溃且点数保持", back.size() == 2, "得到 %d" % back.size())
	_check("结果仍在合法区间", back[1].x >= 0.0 and back[1].x <= 65535.0)


func _test_codec_garbage() -> void:
	print("\n-- 畸形数据（必须静默丢弃）--")
	_check("空数组", StrokeCodec.decode_chunk(PackedByteArray()).is_empty())
	_check("只有 3 字节", StrokeCodec.decode_chunk(PackedByteArray([1, 0, 0])).is_empty())

	# 版本号不对
	var wrong := StreamPeerBuffer.new()
	wrong.put_u8(99)
	wrong.put_u8(0)
	wrong.put_u16(1)
	wrong.put_u8(0)
	wrong.put_u8(0)
	wrong.put_u8(0)
	wrong.put_u8(0)
	wrong.put_u16(1)
	_check("版本不符", StrokeCodec.decode_chunk(wrong.data_array).is_empty())

	# 头声称 100 个点，但一个字节的点数据都没有
	var liar := StreamPeerBuffer.new()
	liar.put_u8(StrokeCodec.VERSION)
	liar.put_u8(0)
	liar.put_u16(1)
	liar.put_u8(0)
	liar.put_u8(0)
	liar.put_u8(0)
	liar.put_u8(0)
	liar.put_u16(100)
	_check("点数撒谎", StrokeCodec.decode_chunk(liar.data_array).is_empty())

	# 点数超出防御上限
	var huge := StreamPeerBuffer.new()
	huge.put_u8(StrokeCodec.VERSION)
	huge.put_u8(0)
	huge.put_u16(1)
	huge.put_u8(0)
	huge.put_u8(0)
	huge.put_u8(0)
	huge.put_u8(0)
	huge.put_u16(60000)
	_check("点数超上限", StrokeCodec.decode_chunk(huge.data_array).is_empty())

	# 随机字节连续灌一万次，只要不崩就算过
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260923
	var survived := true
	for i in range(10000):
		var blob := PackedByteArray()
		var n := rng.randi_range(0, 64)
		for j in range(n):
			blob.append(rng.randi_range(0, 255))
		var r := StrokeCodec.decode_chunk(blob)
		if not r.is_empty():
			@warning_ignore("unused_variable")
			var pts: PackedVector2Array = r["points"]
	_check("一万次随机字节不崩溃", survived)


func _test_codec_batch() -> void:
	print("\n-- 整块画布打包 --")
	var chunks: Array = []
	var sources: Array = []
	for i in range(3):
		var pts := _make_points(20 + i * 15, i)
		sources.append(pts)
		chunks.append(StrokeCodec.encode_chunk(
			i + 1, StrokeCodec.FLAG_BEGIN | StrokeCodec.FLAG_END, _TEST_COLOR, 1, pts))

	var blob := StrokeCodec.encode_batch(chunks)
	var back := StrokeCodec.decode_batch(blob)
	_check("段数一致", back.size() == 3, "得到 %d" % back.size())

	var all_ok := true
	for i in range(mini(back.size(), 3)):
		var d := StrokeCodec.decode_chunk(back[i])
		if d.is_empty() or not _points_equal(sources[i], d["points"]):
			all_ok = false
	_check("每段内容一致", all_ok)

	_check("空 batch 不崩", StrokeCodec.decode_batch(PackedByteArray([99, 0])).is_empty())


# ---------------------------------------------------------------- 画板

func _test_board_roundtrip() -> void:
	print("\n-- 画板分片接收与整块重建 --")
	var a := DrawBoard.new()
	a.size = Vector2(1080, 810)

	var s1 := _make_points(40, 1)
	for c in _split_chunks(1, _TEST_COLOR, 1, s1):
		a.apply_remote_chunk(c)

	var s2 := _make_points(9, 2)
	for c in _split_chunks(2, _TEST_COLOR, 0, s2):
		a.apply_remote_chunk(c)

	_check("收到两条笔迹", a.get_stroke_count() == 2, "得到 %d" % a.get_stroke_count())

	var blob := a.serialize_all()
	var b := DrawBoard.new()
	b.size = Vector2(1080, 810)
	b.load_all(blob)
	_check("重建后笔迹数一致", b.get_stroke_count() == 2, "得到 %d" % b.get_stroke_count())
	if b.get_stroke_count() == 2:
		var p0: PackedVector2Array = b._strokes[0]["points"]
		var p1: PackedVector2Array = b._strokes[1]["points"]
		_check("第一条笔迹点数一致", p0.size() == s1.size(), "%d vs %d" % [p0.size(), s1.size()])
		_check("第一条笔迹坐标一致", _points_equal(p0, s1))
		_check("第二条笔迹坐标一致", _points_equal(p1, s2))

	# 没有 BEGIN 的续包必须被丢弃，不能凭空造出笔迹
	var orphan := StrokeCodec.encode_chunk(999, 0, _TEST_COLOR, 1, _make_points(5, 0))
	var before := a.get_stroke_count()
	a.apply_remote_chunk(orphan)
	_check("孤立续包被丢弃", a.get_stroke_count() == before)

	a.free()
	b.free()


func _test_board_clear() -> void:
	print("\n-- 清空画布 --")
	var a := DrawBoard.new()
	a.size = Vector2(1080, 810)
	for c in _split_chunks(1, _TEST_COLOR, 1, _make_points(30, 0)):
		a.apply_remote_chunk(c)
	_check("清空前有笔迹", a.get_stroke_count() == 1)

	var clear_flags := StrokeCodec.FLAG_CLEAR
	a.apply_remote_chunk(StrokeCodec.encode_chunk(0, clear_flags, _TEST_COLOR, 0, PackedVector2Array()))
	_check("清空后为 0", a.get_stroke_count() == 0)
	a.free()


func _test_quantization() -> void:
	print("\n-- 坐标量化 --")
	var box := Vector2(100, 100)
	_check("左上角", DrawBoard.to_board(Vector2(0, 0), box) == Vector2i(0, 0))
	_check("右下角", DrawBoard.to_board(Vector2(100, 100), box) == Vector2i(4095, 4095))
	_check("中心", DrawBoard.to_board(Vector2(50, 50), box) == Vector2i(2048, 2048))
	_check("越界被夹住", DrawBoard.to_board(Vector2(-50, 500), box) == Vector2i(0, 4095))
	_check("尺寸为 0 不崩", DrawBoard.to_board(Vector2(10, 10), Vector2.ZERO) == Vector2i.ZERO)

	# 同一条笔迹在不同尺寸画板上的相对位置必须一致
	var q1 := DrawBoard.to_board(Vector2(270, 202.5), Vector2(1080, 810))
	var q2 := DrawBoard.to_board(Vector2(540, 405), Vector2(2160, 1620))
	_check("不同分辨率下量化结果一致", q1 == q2, "%s vs %s" % [str(q1), str(q2)])

	var back := DrawBoard.from_board(Vector2i(2048, 2048), Vector2(1080, 810))
	_check("反算回像素", absf(back.x - 540.0) < 1.0 and absf(back.y - 405.0) < 1.0, str(back))


func _test_palette() -> void:
	print("\n-- 调色盘与笔宽 --")
	var swatches := DrawPalette.swatches()
	_check("色板颜色够多", swatches.size() >= 40, "%d 个" % swatches.size())
	_check("色板含黑与白", swatches.has(Color.BLACK) and swatches.has(Color.WHITE))
	var unique := {}
	for color in swatches:
		unique[color.to_rgba32()] = true
	_check("色板没有重复色", unique.size() == swatches.size(),
		"%d/%d" % [unique.size(), swatches.size()])

	# 笔宽无极调节：两端、缩放、以及像素<->量化值的换算都要对
	var narrow := DrawPalette.width_px(0, 1080.0)
	var wide := DrawPalette.width_px(DrawPalette.WIDTH_STEPS - 1, 1080.0)
	_check("最细等于 WIDTH_MIN_PX", is_equal_approx(narrow, DrawPalette.WIDTH_MIN_PX), str(narrow))
	_check("最粗等于 WIDTH_MAX_PX", is_equal_approx(wide, DrawPalette.WIDTH_MAX_PX), str(wide))
	_check("最粗比最细细 20 倍以上", wide > narrow * 20.0, "%f vs %f" % [wide, narrow])
	_check("宽度随画板等比缩放", is_equal_approx(DrawPalette.width_px(0, 2160.0), narrow * 2.0))
	_check("像素与量化值能互相换算",
		DrawPalette.width_q_from_px(wide, 1080.0) == DrawPalette.WIDTH_STEPS - 1,
		"%d" % DrawPalette.width_q_from_px(wide, 1080.0))
	_check("中间值落在两端之间", narrow < DrawPalette.width_px(128, 1080.0) and
		DrawPalette.width_px(128, 1080.0) < wide)


func _test_uri() -> void:
	print("\n-- 邀请串 --")
	var uri := Protocol.build_uri("192.168.1.5", 8910)
	_check("生成格式", uri == "godotlan://192.168.1.5:8910", uri)

	var parsed := Protocol.parse_uri(uri)
	_check("解析 IP", parsed.get("ip", "") == "192.168.1.5", str(parsed))
	_check("解析端口", int(parsed.get("port", 0)) == 8910, str(parsed))

	_check("拒绝 http", Protocol.parse_uri("http://1.2.3.4:80").is_empty())
	_check("拒绝缺端口", Protocol.parse_uri("godotlan://1.2.3.4").is_empty())
	_check("拒绝端口越界", Protocol.parse_uri("godotlan://1.2.3.4:99999").is_empty())
	_check("容忍空白", Protocol.parse_uri("  godotlan://10.0.0.2:8912  ").get("port", 0) == 8912)


# ---------------------------------------------------------------- 工具

func _make_points(n: int, phase: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var x := 200.0
	var y := 300.0
	for i in range(n):
		x = clampf(x + 7.0 + float((i * 13 + phase) % 41), 0.0, 4095.0)
		y = clampf(y + float((i * 29 + phase) % 81) - 40.0, 0.0, 4095.0)
		pts.append(Vector2(round(x), round(y)))
	return pts


func _split_chunks(stroke_id: int, color: Color, width_q: int, pts: PackedVector2Array) -> Array:
	var out: Array = []
	var i := 0
	var first := true
	while i < pts.size():
		var n := mini(DrawBoard.MAX_POINTS_PER_CHUNK, pts.size() - i)
		var part := pts.slice(i, i + n)
		i += n
		var flags := 0
		if first:
			flags |= StrokeCodec.FLAG_BEGIN
		if i >= pts.size():
			flags |= StrokeCodec.FLAG_END
		out.append(StrokeCodec.encode_chunk(stroke_id, flags, color, width_q, part))
		first = false
	return out


func _points_equal(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if not a[i].is_equal_approx(b[i]):
			return false
	return true


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("  [OK]   ", label)
	else:
		_failed += 1
		print("  [FAIL] ", label, "   ", detail)


func _finish() -> void:
	print("\n=== 通过 %d，失败 %d ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
