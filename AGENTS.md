# AGENTS.md — 多 agent 协作规则

本仓库采用「每个 agent 一个 git worktree + 一个功能分支」的并行开发模式。
在本仓库工作的任何 agent，动手前必须先读完本文件。

## 0. 项目背景

局域网多人聚会游戏合集，引擎为 Godot 4.7。首发三款：UNO、你画我猜、画猜接龙。
**只做局域网联机，没有服务器、没有账号系统。**
完整设计见根目录的 `聚会游戏项目规划.md`，动手前请先读它。

## 1. 分支与工作目录纪律

- 每个 agent 在自己的 worktree 中工作，路径形如 `D:\Godot Progame\wt-<name>`。
- **禁止执行 `git checkout` / `git switch` / `git worktree` / `git rebase` / `git merge` / `git push`。**
  你已经在正确的分支上了。切分支会破坏其他 agent 的工作区。
- 禁止访问其他人的 `wt-*` 目录。
- 集成分支 `main` 由 root agent 负责合并，你只提交自己的分支。

## 2. 文件所有权

| 路径 | 所有者 |
|---|---|
| `core/**`、`project.godot` | net-core agent |
| `drawing/**`、`games/draw_guess/**` | draw-guess agent |
| `games/telestrations/**` | telestrations agent |
| `games/uno/**` | uno agent |
| `games/base_minigame.gd` | 冻结契约，任何人不得修改 |
| `assets/**`、`data/**` | 同一文件只允许一个 agent 修改 |

修改不属于你的文件视为严重错误。

## 3. 冻结契约

以下文件是并行开发的基础，已经冻结。如果你认为必须改动它们：

**停下来。** 不要动它，把你的需求写进 `docs/contract-requests.md`，由 root agent 统一裁决后再统一修改。

- `games/base_minigame.gd` —— 所有小游戏实现的接口
- `core/net/protocol.gd` —— 报文与通道定义
- `core/net/transport.gd` —— 连接抽象
- `drawing/board.gd` —— 画板公开 API

这一条是硬约束。并行开发最常见的失败就是接口漂移：两个 agent 各自发明一套 API，
合并时不是解冲突的问题，而是逻辑根本对不上。

## 4. Godot 相关纪律

- **`.godot/` 已被 gitignore，绝对不要提交它。**
- `*.uid`（Godot 4.4+ 的资源引用）和 `*.import` 文件**必须提交**。
- **一个场景只有一个所有者。** 不要编辑不属于你的 `.tscn` / `.tres`。
- **非资源数据文件必须在导出预设的 `include_filter` 里列出来**，否则不会被打进导出包。
  词库 `data/words/words.txt` 就是例子。这类问题的特征是：编辑器里完全正常，
  装到手机上才炸，而且日志还看不到。改 `export_presets.cfg` 前先读 README 的「导出到手机」。
- 提交前用 `--headless` 跑一次导入，确认工程没被改坏：

  ```powershell
  & 'D:\Godot Progame\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe' --headless --path . --import
  ```

- 如果 Godot 在仓库根目录生成了 `export_templates/`、`feature_profiles/`、`script_templates/`、
  `text_editor_themes/` 这类空目录，说明编辑器数据目录不可写。**删掉它们，不要提交。**

## 5. 提交规范

- 格式：`<type>(<scope>): <描述>`，type 用 `feat` / `fix` / `refactor` / `test` / `docs` / `chore`。
- scope 用模块名：`uno`、`draw-guess`、`telestrations`、`net`、`drawing`。
- 一次提交只做一件事。你自己的分支上允许 WIP 提交。
- 每完成一个可独立验证的里程碑，在提交信息里写清楚**验收方式**（怎么跑、看什么）。

## 6. 不要做的事

- 不要引入第三方插件或依赖（`addons/` 保持为空，除非 root agent 批准）。
- 不要写任何服务器、账号、HTTP 请求相关代码——本项目只做局域网。
- 不要在代码里硬编码 UI 文本，用 `tr()`；文本资源放 `data/`。
- 不要为了让代码能跑起来而修改冻结契约或 `project.godot`。
- 不要在权威端之外做玩法判定。**所有判定逻辑只在 `multiplayer.is_server()` 为真时执行。**
