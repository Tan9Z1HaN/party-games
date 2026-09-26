class_name TourGame
extends MiniGame

## 《环游中国》的房间层适配。
##
## **联机还没做**（第 3 步），所以现在只提供元信息和配置表——
## 有这两样，大厅和游戏列表就能自动长出这个游戏。
##
## 单机不走这一层：单机是「一个真人 + 若干 AI」，牌桌自己拿 rules.gd 跑，
## 跟 UNO 那边是一个路子。

const ID := "tour"


func get_meta_info() -> Dictionary:
	return {
		"id": ID,
		"name": tr("环游中国"),
		"min_players": 2,
		# 上限 6 而不是 8：这是轮流制，8 个人等一轮太久
		"max_players": 6,
		"est_minutes": 12,
		"scene": "res://games/tour/main.tscn",
		"solo": true,
		"online": false,     ## 联机还没接，先别让人在大厅开起来
	}


func get_config_schema() -> Array:
	return [
		{
			"id": "rounds", "label": tr("轮数"), "type": "int",
			"default": 8, "min": 4, "max": 16,
			"help": tr("每人走几轮。轮数越多，买卖越充分，但一局也越长"),
		},
	]
