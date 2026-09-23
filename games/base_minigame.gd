class_name MiniGame
extends Node

## 所有小游戏实现的统一接口（冻结契约，勿改）。
##
## 房间层（Room）只通过本文件的方法与小游戏交互，不关心具体玩法。
##
## 生命周期：
##     setup(players, cfg)
##       -> start_round()
##       -> [ on_player_input() / tick() 内部推进 ]
##       -> round_finished -> 若还有回合则再次 start_round()
##       -> game_finished
##       -> get_results()
##       -> get_replay_data()（可选，用于结算展示与分享图）
##
## 权威端 = 房主，即 multiplayer.is_server() 为 true 的一侧。
## **所有判定逻辑只在权威端运行**，客户端只负责表现与输入采集。

signal round_started(round_index: int)
signal round_finished(round_index: int)
signal game_finished()

## 请求房间层把 payload 广播给所有玩家（权威端调用）
signal broadcast_requested(payload: PackedByteArray)

## 请求房间层把 payload 单发给某个玩家（权威端调用）。
## 用于隐藏信息，例如 UNO 的手牌。
signal to_player_requested(peer_id: int, payload: PackedByteArray)


func get_meta_info() -> Dictionary:
	## 静态元信息，用于大厅展示。子类必须重写。返回：
	##   {
	##     id: String,          # "uno" / "draw_guess" / "telestrations"
	##     name: String,        # 已本地化的显示名
	##     min_players: int,
	##     max_players: int,
	##     est_minutes: int,    # 单局预估时长
	##     scene: String,       # res://games/<id>/main.tscn
	##   }
	push_error("MiniGame.get_meta_info() 未实现")
	return {}


func get_config_schema() -> Array:
	## 房间内可配置项，房间层据此自动生成配置界面。返回数组，每项：
	##   {
	##     id: String,
	##     label: String,                     # 已本地化
	##     type: "bool" | "int" | "enum",
	##     default: Variant,
	##     min: int, max: int,                # type == "int" 时有效
	##     options: Array,                    # type == "enum" 时有效，[{value, label}]
	##     help: String,                      # 可选说明
	##   }
	## 例如 UNO 的家规开关（叠牌、7-0、抢出）就定义在这里。
	return []


func setup(players: Array, cfg: Dictionary) -> void:
	## 开局前调用一次。
	## players: 玩家信息数组，权威端与客户端顺序一致。
	## cfg: 按 get_config_schema() 填好用户选择的配置。
	push_error("MiniGame.setup() 未实现")


func start_round() -> void:
	## 开始下一回合。由房间层调用。不要在这里自建 Timer。
	push_error("MiniGame.start_round() 未实现")


func tick(delta: float) -> void:
	## 由房间层每帧调用，权威端与客户端都会调用。
	## 计时、超时、动画推进都放在这里，便于统一暂停与重连恢复。
	pass


func on_player_input(peer_id: int, payload: PackedByteArray) -> void:
	## 收到玩家输入。**只在权威端调用**，且 peer_id 已由房间层校验过来源。
	## 非法输入一律静默丢弃，不要崩溃。
	pass


func on_player_disconnected(peer_id: int) -> void:
	## 玩家断线但尚未离开房间。默认什么都不做，由子类的超时逻辑兜底。
	pass


func on_player_reconnected(peer_id: int) -> void:
	## 玩家重连成功。若该玩家持有隐藏信息（例如 UNO 手牌），
	## 权威端需在这里把私有状态重新单发给他。
	pass


func on_player_left(peer_id: int) -> void:
	## 玩家彻底离开。**必须保证回合流程不卡死**，
	## 例如画猜接龙要跳过他的格子，UNO 要把他移出回合顺序。
	pass


func is_finished() -> bool:
	## 所有回合是否已结束（为真时才允许调用 get_results()）。
	return true


func get_results() -> Array:
	## 本局结算。返回：[{ peer_id: int, score: int }]
	## 房间层的计分服务负责累加总分，不要在这里改总分。
	return []


func get_replay_data() -> Dictionary:
	## 揭晓回放 / 分享长图所需数据，结构由各游戏自定义，房间层不解释它。
	## 画猜接龙返回密码本全貌，你画我猜返回题目与画手的对应关系。
	return {}
