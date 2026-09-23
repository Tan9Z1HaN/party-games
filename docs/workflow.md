# 多 agent 并行开发流程

## 为什么用 worktree 而不是切分支

所有 agent 共享同一个文件系统。如果直接用 `git checkout` 切分支，其他正在
同一个目录里干活的 agent，工作区文件会被当场换掉。

**git worktree** 解决这个问题：同一个仓库、多个独立的工作目录、各自锁定一个分支，
而 git 的对象库仍然共享（不像克隆那样复制多份历史）。

额外好处：git **不允许同一个分支在两个工作树里同时检出**，重复了会直接报错。
这比靠约定可靠。

## 目录布局

```
D:\Godot Progame\
├── party-games\        ← 主仓库，常驻 main 分支，只用来集成
├── wt-net-core\        ← feat/net-core     联网与房间框架
├── wt-uno\             ← feat/uno          UNO
├── wt-draw-guess\      ← feat/draw-guess   绘制引擎 + 你画我猜
└── wt-telestrations\   ← feat/telestrations 画猜接龙（wave 2）
```

`.git` 只有主仓库那一份，三个工作树共用。

## 常用命令

```powershell
$repo = 'D:\Godot Progame\party-games'

# 新建工作树 + 分支
git -C $repo worktree add 'D:\Godot Progame\wt-telestrations' -b feat/telestrations

# 查看现状
git -C $repo worktree list
git -C $repo branch -a

# 看某个分支的提交
git -C $repo log --oneline main..feat/uno

# 合并（由 root agent 执行，agent 自己不许 merge）
git -C $repo merge --no-ff feat/uno

# 收工清理
git -C $repo worktree remove 'D:\Godot Progame\wt-uno'
git -C $repo branch -d feat/uno
```

## 每条分支都在干什么

| 分支 | 工作树 | 所有权范围 |
|---|---|---|
| `feat/net-core` | `wt-net-core` | `core/**`、`project.godot` |
| `feat/uno` | `wt-uno` | `games/uno/**` |
| `feat/draw-guess` | `wt-draw-guess` | `drawing/**`、`games/draw_guess/**`、`data/words/**` |
| `feat/telestrations` | 待建 | `games/telestrations/**` |

所有权必须**互不重叠**。这是并行开发能成立的前提，比什么工具都重要。

## 合并流程（Godot 项目专用）

Godot 的合并有它自己的坑，所以流程比普通项目多两步：

1. **合并前**确认对方跑过 `--headless --import` 且无解析错误。
2. `git merge --no-ff <branch>`。
3. **合并后立刻打开一次 Godot 编辑器**（或跑一次 `--import`）。
   Godot 4.4+ 的场景用 `uid://` 引用资源，跨分支合并后可能留下悬空引用，
   让编辑器跑一遍会重新生成 `.uid` 并修正引用。
4. 检查 `git status`，把编辑器修正后的 `.uid` / `.import` 变更一起提交。
5. 跑一次实机验证（headless 主机 + 客户端窗口）。

### 几个必知的合并雷区

| 文件 | 为什么会冲突 | 规矩 |
|---|---|---|
| `project.godot` | 注册 autoload、输入映射都会改它 | 只有 net-core agent 能改 |
| `.tscn` / `.tres` | Godot 保存时整个文件重写 | 一个场景只有一个所有者 |
| `uid://` 引用 | 跨分支合并可能产生悬空引用 | 合并后开一次编辑器 |
| `.png` / `.ogg` | 二进制，无法合并 | 一个素材一个所有者 |
| `.godot/` | 导入缓存，会疯狂冲突 | 已在 gitignore，别加回来 |

## 把规则下发给 agent

仓库根目录的 `AGENTS.md` 是唯一的规则来源，所有 agent 自动读同一份。
里面写死了三件事：

1. **分支纪律** —— 不许切分支、不许 merge、不许 push。
2. **文件所有权表** —— 越界即视为严重错误。
3. **冻结契约清单** —— `base_minigame.gd`、`protocol.gd`、`transport.gd`、`board.gd`
   不许改签名。需要改就写进 `docs/contract-requests.md`，由 root 统一裁决。

第 3 条是并行开发真正的命门。两个 agent 各自发明一套 API，合并时不是解冲突的问题，
而是逻辑根本对不上。**所以接口必须先冻结，再并行。**

## 不要并行化地基

这个项目真正适合并行的只有三款游戏本身。框架层一旦有两个人同时写，
冲突成本会超过并行收益。所以 wave 0（接口冻结）永远是串行的。
