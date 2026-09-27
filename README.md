# 聚在一起

局域网多人聚会游戏合集。房主开个热点，或者大家连上同一个 Wi-Fi，其他人把地址填进去就能进房。
不需要注册、不需要联网、也不需要有台服务器在跑——服务器就是房主那台手机。

> 还在做。你画我猜、UNO、环游中国都能局域网联机玩了，UNO 和环游中国还有单机对电脑的模式。

Android 版下载：https://tan9z1han.dpdns.org/apps/party-games/

## 游戏

- **你画我猜**　2~8 人，一局 5~8 分钟
- **UNO**　2~8 人，一局 5~10 分钟，也能单机对电脑
- **环游中国**　2~6 人，一局 10~15 分钟，也能单机对电脑
- **画猜接龙**　3~8 人，还没做

有隐藏手牌的游戏（UNO、环游中国）才能跟电脑玩，因为得藏牌；
你画我猜没什么可藏的，只能大家连起来玩。

## 跑起来

电脑上用 Godot 4.7 打开工程按 F5，或者：

```powershell
.\tools\play.ps1
```

打到手机上：

```powershell
# 导出调试版
& 'D:\Godot Progame\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe' `
    --headless --export-debug "Android" 'build\partygames.apk'

# 装到已连接的设备或模拟器
adb install -r 'build\partygames.apk'
```

APK 直接拖进模拟器窗口也能装。

第一次导出前要先装导出模板（编辑器 → 管理导出模板），并在编辑器设置里填好 Android SDK 和
Java SDK 路径，这一步最容易卡住，`docs/开发笔记.md` 里记了。

发给别人的包要用 `--export-release`，并且别勾那个「导出为调试」。

## 结构

Godot 4.7（GDScript），联网走 ENet（UDP），只跑局域网，没有在线服务。

代码分三层，依赖是单向的：游戏层认识框架层，框架层不认识任何具体游戏。

```
games/      游戏层    每款游戏实现同一个 MiniGame 接口
   │
core/       框架层    连接、房间、游戏注册表、通用 UI 主题
   │
drawing/    绘制引擎  你画我猜与画猜接龙共用的画板
```

几条定得比较死的规矩：

- **逻辑全在主机上跑。** 房主手机算一切、做判定，客户端只管画和采集输入。
  规则代码因此只有一份，主机和客户端共用。
- **要保密的数据单发，不进广播。** 你画我猜的答案、UNO 的手牌，只发给对应的人。
  走广播的话，一个抓包工具就能看穿全场。
- **加游戏不改框架。** 新游戏只声明自己支持几人、有哪些配置项，大厅的界面和列表据此生成。
  目前加一款游戏不用动 `app/` 一行代码。

主要目录：

```
app/                     应用外壳：选游戏 → 建房/加入 → 大厅 → 对局
core/
  net/                   传输层与协议定义
  room/                  房间控制器：握手、玩家列表、报文路由
  games_catalog.gd       游戏注册表
  ui/                    浅色主题、HSV 取色器
drawing/                 画板与笔迹二进制编解码
games/
  base_minigame.gd       所有小游戏实现的统一接口
  draw_guess/            你画我猜
  uno/                   UNO
tools/                   构建与测试脚本
data/                    词库等运行时数据
docs/                    设计与开发文档
```

## 测试

```powershell
.\tools\run_tests.ps1        # 几秒钟跑完
```

十二套用例、约一千项断言，覆盖规则引擎、绘制引擎、开屏与返回栈、构建配置和联机报文编解码。

联机那块要起多个进程，得单独跑：

```powershell
.\tools\tests\run_net_smoke.ps1    # 连接层：握手、玩家列表、报文路由
.\tools\tests\run_net_round.ps1    # 你画我猜：打完整局，比对三个进程各自记录到了什么
.\tools\tests\run_net_uno.ps1      # UNO：跨进程打完一整局，比对三边的赢家
.\tools\tests\run_net_tour.ps1     # 环游中国：跨进程打到有人破产，比对三边的赢家
```

`run_net_round.ps1` 是里面最值钱的一个：起 1 个主机 + 2 个客户端真的打完 3 回合，然后把三边的
结算记录、分数、公开答案摆在一起比对，顺便检查非画手有没有拿到不该拿的信息。
「两边状态不一致」这类问题在单个进程里看全是对的，只有把两边的记录摊开才露馅。

### 截图

「屏幕显示不全」「牌压在按钮上」这种问题测试一条都拦不住，测试不看像素。
所以另有两个要开窗口跑的脚本：

```powershell
# 每个界面按真实比例各截一张（设计稿 / 手机长屏 / 桌面宽窗 / 平板）
& $godot --path . --script res://tools/tests/screenshot_matrix.gd

# 伪 3D shader 在不同旋转角下排成一张对照图
& $godot --path . --script res://tools/tests/shader_probe.gd
```

**都不能加 `--headless`**，headless 没有渲染，截出来全是空的。图片落在 `user://`。

## 开发

主干是 `main`，试验性改动开短分支，做完就并。

几个不能忘的：

- `*.ps1` 必须是纯 ASCII，有测试盯着。PowerShell 5.1 会按系统代码页解码无 BOM 的 UTF-8，
  中文注释可能把换行符吞掉，脚本就废了。
- UI 文本走 `tr()`，别硬编码在代码里。
- 新增的 `*.uid` 要提交，`.godot/` 不要提交。

还有些零碎的坑——Godot 编辑器会改写 `project.godot`、非资源文件要显式加进导出过滤器、
安卓的网络权限默认是关的——都记在 [`docs/开发笔记.md`](docs/开发笔记.md) 里，动手前翻一下能省不少时间。

## 其他文档

- [`聚会游戏项目规划.md`](聚会游戏项目规划.md)　玩法设计、联网架构、排期和上线指标
- [`docs/开发笔记.md`](docs/开发笔记.md)　工程实践中的坑
- [`docs/workflow.md`](docs/workflow.md)　多分支并行开发的流程
- [`docs/环游中国（大富翁玩法）规划.md`](docs/环游中国（大富翁玩法）规划.md)　40 格中国城市棋盘、规则取舍、竖屏界面
- [`AGENTS.md`](AGENTS.md)　协作与代码约定

## 许可

MIT，见 [LICENSE](LICENSE)。拿去用、拿去改、拿去卖都行，保留版权声明就好。
