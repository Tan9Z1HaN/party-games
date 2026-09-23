# PartyGames

局域网多人聚会游戏合集。房主手机开热点或同处一个 Wi-Fi，其他人扫码进房，30 秒内开局。

**引擎**：Godot 4.7 stable　|　**平台**：Android / iOS　|　**联网**：仅局域网，无在线服务

## 首发的三款游戏

| 游戏 | 人数 | 单局时长 |
|---|---|---|
| 你画我猜 | 3~8 | 5~8 min |
| 画猜接龙 | 3~8 | 8~12 min |
| UNO（派对规则集） | 2~8 | 5~10 min |

## 三条必须守住的原则

1. **房主即服务端**（Host-as-Server）。房主手机跑权威逻辑，同时也是玩家。游戏逻辑代码只有一份。
2. **配对以二维码为主路径**，UDP 广播发现是加分项，手动输入 IP 是兜底。路由器客户端隔离会让广播发现失效。
3. **首次连接成功率 ≥ 95%**。这是局域网游戏的生死线，比任何新玩法都重要。

## 目录结构

```
res://
├── addons/                 # 第三方插件
├── assets/                 # 美术与音频原始资源
│   ├── audio/
│   ├── fonts/
│   └── textures/
├── core/                   # 与具体游戏无关的框架层
│   ├── autoload/           # net / discovery / session / audio / profile
│   ├── net/                # protocol / codec / qr
│   └── ui/                 # 通用控件（按钮、弹窗、倒计时、头像）
├── data/                   # 词库、卡牌定义、规则配置
│   ├── rules/
│   └── words/
├── docs/                   # 设计文档
├── drawing/                # 绘制引擎（你画我猜 + 画猜接龙共用）
│   ├── board.tscn
│   ├── board.gd
│   ├── stroke_codec.gd
│   └── palette.gd
└── games/
    ├── base_minigame.gd    # 所有游戏实现的统一接口
    ├── draw_guess/
    ├── telestrations/
    └── uno/
        ├── deck.gd
        ├── rules.gd        # 纯逻辑规则层
        └── ui/
```

> 空目录不会被 Git 跟踪。首次 `git init` 前如果想保留骨架，在各空目录放一个占位文件即可。

## 游戏实现统一接口

每款游戏继承 `games/base_minigame.gd`，房间层只调用这几个方法：

```gdscript
func get_meta_info() -> GameMeta      # 名称、人数范围、时长、图标
func get_config_schema() -> Array     # 房间内可配置项（回合数、家规）
func setup(players, cfg) -> void
func start_round() -> void
func on_player_input(peer_id, payload) -> void
func is_finished() -> bool
func get_results() -> Array
func get_replay_data() -> Dictionary  # 揭晓回放 / 分享长图
```

## 完整规划

详见 [聚会游戏项目规划.md](./聚会游戏项目规划.md)：玩法设计、局域网架构、排期（约 16 周）、风险清单、上线指标。

## 第一个里程碑（M0，1.5 周）

搭一个 3 台真机的局域网原型（至少 1 台 iOS）：一个房间标题 + 二维码 + 玩家列表，验证三种配对方式各成功 10/10 次。

这一步要在 Windows 上用 `--headless` 起一个房主进程，配上真机做客户端，先把 iOS 本地网络权限流程跑通。
