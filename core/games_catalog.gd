class_name GamesCatalog
extends RefCounted

## 游戏注册表。
##
## 房间层和大厅不认识任何具体游戏，只认这里的 id。
## 加一款新游戏 = 在 REGISTRY 里加一条 + 把逻辑脚本和界面场景放好，
## 大厅的游戏列表、配置界面、对局场景装载都会自动跟上。
##
## 这里**只存路径**。名字、人数范围、预估时长一律从游戏的 get_meta_info() 拿，
## 配置项从 get_config_schema() 拿——避免两处各写一份然后慢慢对不上。
##
## 注意：本文件不许出现任何具体游戏的字段名
## （比如"回合数""叠牌"）。加游戏时不该改这里。

const REGISTRY := {
	"draw_guess": {
		"logic": "res://games/draw_guess/draw_guess_game.gd",
		"scene": "res://games/draw_guess/main.tscn",
	},
	"uno": {
		"logic": "res://games/uno/uno_game.gd",
		"scene": "res://games/uno/main.tscn",
	},
	"tour": {
		"logic": "res://games/tour/game.gd",
		"scene": "res://games/tour/main.tscn",
	},
}

## 元信息与配置项缓存。每次查都 new 一个游戏对象太浪费，
## 而且这两样在一次会话里不会变。
static var _meta_cache := {}
static var _schema_cache := {}


static func has(id: String) -> bool:
	return REGISTRY.has(id)


static func ids() -> PackedStringArray:
	var out := PackedStringArray()
	for id in REGISTRY:
		out.append(String(id))
	out.sort()
	return out


## 大厅的游戏列表用这个。
## 返回 [{ id, scene, name, min_players, max_players, est_minutes }]
static func entries() -> Array:
	var out: Array = []
	for id in ids():
		var meta := meta_for(id)
		if meta.is_empty():
			continue
		out.append({
			"id": id,
			"scene": scene_for(id),
			"name": String(meta.get("name", id)),
			"min_players": int(meta.get("min_players", 2)),
			"max_players": int(meta.get("max_players", 8)),
			"est_minutes": int(meta.get("est_minutes", 5)),
			# 能力标记：游戏自己声明支不支持单机 / 联机。
			# 大厅和菜单按这个决定显示哪些入口，而不是靠判断游戏 id。
			"solo": bool(meta.get("solo", false)),
			"online": bool(meta.get("online", true)),
		})
	return out


static func scene_for(id: String) -> String:
	if not REGISTRY.has(id):
		return ""
	return String(REGISTRY[id]["scene"])


static func display_name(id: String) -> String:
	var meta := meta_for(id)
	if meta.is_empty():
		return id
	return String(meta.get("name", id))


static func meta_for(id: String) -> Dictionary:
	if _meta_cache.has(id):
		return _meta_cache[id]
	var game := create_logic(id)
	if game == null:
		return {}
	var meta := game.get_meta_info()
	game.free()
	_meta_cache[id] = meta
	return meta


static func schema_for(id: String) -> Array:
	if _schema_cache.has(id):
		return _schema_cache[id]
	var game := create_logic(id)
	if game == null:
		return []
	var schema := game.get_config_schema()
	game.free()
	_schema_cache[id] = schema
	return schema


## 默认配置完全按游戏自己声明的 schema 来。
## 加一款新游戏时，这里一个字都不用改。
static func default_config(id: String) -> Dictionary:
	var out := {}
	for item in schema_for(id):
		out[item["id"]] = item["default"]
	return out


## 造一个游戏逻辑对象（还没 setup，也没挂进场景树）。
## 调用方负责 free()——大厅查元信息、房间层开局都走这里。
static func create_logic(id: String) -> MiniGame:
	if not REGISTRY.has(id):
		push_error("没有注册的游戏：%s" % id)
		return null
	var game_script: Script = load(String(REGISTRY[id]["logic"]))
	if game_script == null:
		push_error("游戏逻辑脚本加载失败：%s" % REGISTRY[id]["logic"])
		return null
	return game_script.new() as MiniGame
