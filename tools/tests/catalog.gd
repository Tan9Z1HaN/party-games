extends SceneTree

## 游戏注册表检查。
##
## 加一款新游戏时最容易漏的几件事：忘了填某个元信息字段、schema 用了
## 大厅渲染不出来的控件类型、场景路径写错、配置项 id 重复。
## 这些在编辑器里都不会报错，只有真的进大厅点一遍才发现。
## 所以在这里一次性验完——新游戏接进来时跑一次就知道有没有漏。
##
##   godot --headless --path . --script res://tools/tests/catalog.gd

var _passed := 0
var _failed := 0


func _initialize() -> void:
	print("=== 游戏注册表检查 ===")
	_test_every_game()
	_finish()


func _test_every_game() -> void:
	var entries := GamesCatalog.entries()
	_check("注册表非空", entries.size() > 0, "%d 款" % entries.size())

	for entry in entries:
		var id := String(entry["id"])
		print("\n-- %s --" % id)

		var game := GamesCatalog.create_logic(id)
		_check("逻辑脚本能实例化", game != null)
		if game == null:
			continue

		var meta := game.get_meta_info()
		for key in ["id", "name", "min_players", "max_players", "scene"]:
			_check("元信息里有 %s" % key, meta.has(key), str(meta.keys()))
		_check("元信息里的 id 和注册表一致",
			String(meta.get("id", "")) == id, "%s vs %s" % [meta.get("id", ""), id])
		_check("人数范围合法",
			int(meta.get("min_players", 0)) >= 2
				and int(meta.get("max_players", 0)) >= int(meta.get("min_players", 0)),
			"%d~%d" % [meta.get("min_players", 0), meta.get("max_players", 0)])

		var scene_path := GamesCatalog.scene_for(id)
		_check("场景文件存在", ResourceLoader.exists(scene_path), scene_path)

		_test_schema(game)
		game.free()


## 配置项必须是大厅渲染得出来的类型，否则玩家在大厅只会看到一个空白格。
func _test_schema(game: MiniGame) -> void:
	var schema := game.get_config_schema()
	_check("配置项数量可控", schema.size() <= 12, "%d 项" % schema.size())

	var seen := {}
	for item in schema:
		var id := String(item.get("id", ""))
		_check("%s 声明完整" % id,
			not id.is_empty() and item.has("label") and item.has("type") and item.has("default"),
			str(item.keys()))
		_check("%s 的 id 不重复" % id, not seen.has(id))
		seen[id] = true

		var kind := String(item.get("type", ""))
		_check("%s 的类型大厅能渲染（%s）" % [id, kind], kind in ["bool", "int", "enum"])
		if kind == "int":
			_check("%s 有 min/max" % id, item.has("min") and item.has("max"))
		elif kind == "enum":
			_check("%s 有非空 options" % id,
				item.has("options") and (item["options"] as Array).size() > 0)

	# 默认配置必须和 schema 一一对应，否则房主没动过的项会传不过去
	var game_id := String(game.get_meta_info().get("id", ""))
	var defaults := GamesCatalog.default_config(game_id)
	_check("默认配置覆盖全部配置项", defaults.size() == schema.size(),
		"%d vs %d" % [defaults.size(), schema.size()])


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
