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

## 当前进度

| 模块 | 状态 |
|---|---|
| 绘制引擎（笔迹编解码 / 画板 / 坐标量化） | ✅ 完成，71 项测试 |
| 你画我猜（规则 / 词库 / 界面） | ✅ 完成，可单机热座试玩，81 + 41 项测试 |
| 局域网联网层 | ⏳ 待做（分支 `feat/net-core`） |
| UNO | ⏳ 待做（分支 `feat/uno`） |
| 画猜接龙 | ⏳ 待做（复用绘制引擎） |

## 怎么跑

用 Godot 4.7 打开本工程，按 F5。主场景是 `games/draw_guess/main.tscn`。

单机热座玩法：选人数和回合数 → 开始 → 把手机交给当前画手 → 画手选词、作画 →
其他人口头喊答案，画手点对应玩家的名字记分（也可以用下方输入框代某位玩家打字猜）→ 结算 → 下一回合。

联网接入时 `games/draw_guess/main.gd` 只需要改两处接线：
`board.stroke_chunk` 改成交给房间层广播，房间层收到的 `stroke_forwarded` 分发给**远端**画板。
本机画手的笔迹已经本地渲染过了，不要再 apply 一次，否则会重影。

## 测试

```powershell
.\tools\run_tests.ps1
```

三套用例：

| 用例 | 覆盖什么 | 数量 |
|---|---|---|
| `drawing/tests/run_tests.gd` | 笔迹编解码往返、边界坐标、畸形数据、分片重组、坐标量化 | 71 |
| `games/draw_guess/tests/run_tests.gd` | 词库加载、同义词匹配、报文编解码、完整回合、超时兜底、画手中途离开 | 81 |
| `games/draw_guess/tests/smoke_scene.gd` | 真的实例化场景并像玩家一样把一局点完 | 41 |

Godot 没有跑起来时容易撞上一个坑：如果 `%APPDATA%\Godot` 不可写，
引擎在创建 `user://logs` 失败后会直接崩溃（访问违例）。
正常情况下不会遇到，受限环境里把 `APPDATA` / `LOCALAPPDATA` 指到可写目录即可。

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
