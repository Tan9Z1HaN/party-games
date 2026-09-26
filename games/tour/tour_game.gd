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
			# 胜利条件是「把别人搞破产」，所以没有"打几轮"这回事。
			# 这一项是保险丝：万一谁都不破产，到上限就按资产结算。
			# 默认 0（不限）——正常局走不到它。
			"id": "max_rounds", "label": tr("回合上限（0 为不限）"), "type": "int",
			"default": 0, "min": 0, "max": 100,
			"help": tr("正常局靠破产结束。这一项只是防止一局无限拖下去"),
		},
	]
