class_name UnoGame
extends MiniGame

## UNO 的 MiniGame 适配层。
##
## 规则本身在 rules.gd 里，是纯逻辑；这一层负责把它接到房间框架上。
## **联机部分还没做**（项目顺序是先让单机能玩，再接联机），
## 所以目前这里只有元信息和配置表是完整的。
##
## 单机模式不走这一层：单机是「一个真人 + 若干 AI」，没有房间，
## 牌桌自己拿 rules.gd 跑就行。这一层的 setup/tick 等联机时再补。

const ID := "uno"


func get_meta_info() -> Dictionary:
	return {
		"id": ID,
		"name": tr("UNO"),
		"min_players": 2,
		"max_players": 8,
		"est_minutes": 10,
		"scene": "res://games/uno/main.tscn",
		"solo": true,        ## 支持单机对电脑
		"online": false,     ## 联机还没接，先别让人在大厅开起来
	}


func get_config_schema() -> Array:
	return [
		{
			"id": "stacking", "label": tr("叠牌（+2 叠 +2）"),
			"type": "bool", "default": false,
		},
		{
			"id": "stack_wild4", "label": tr("+4 叠 +4"),
			"type": "bool", "default": false,
		},
		{
			"id": "draw_and_play", "label": tr("摸到能出就出"),
			"type": "bool", "default": true,
		},
		{
			"id": "auto_pass", "label": tr("摸到不能出自动过"),
			"type": "bool", "default": true,
		},
	]
