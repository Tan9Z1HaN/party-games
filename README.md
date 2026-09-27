# 聚在一起

局域网多人聚会游戏合集。房主开个热点，或者大家连上同一个 Wi-Fi，其他人把地址填进去就能进房。

> **项目状态：** 你画我猜、UNO 与环游中国都已可局域网联机游玩；UNO 与环游中国另有单机对电脑模式。

Android 版下载：https://tan9z1han.dpdns.org/apps/party-games/

---

## 游戏

- **你画我猜**　2~8 人，一局 5~8 分钟
- **UNO**　2~8 人，一局 5~10 分钟，也能单机对电脑
- **环游中国**　2~6 人，一局 10~15 分钟，也能单机对电脑
- **画猜接龙**　还没做

有隐藏手牌的游戏才能跟电脑玩，因为得藏牌；你画我猜没什么可藏的，只能连起来玩。

---

### 在电脑上运行

用 Godot 4.7 打开工程目录按 `F5`，或者用附带的脚本：

```powershell
.\tools\play.ps1
```

### 构建到手机

```powershell
# 导出调试版 APK
& 'D:\Godot Progame\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe' `
    --headless --export-debug "Android" 'build\partygames.apk'

# 安装到已连接的设备或模拟器
adb install -r 'build\partygames.apk'
```

也可以把 APK 直接拖进模拟器窗口安装。

> 首次导出前需要安装导出模板（编辑器 → 管理导出模板），并在编辑器设置里
> 填好 Android SDK 与 Java SDK 路径。详见 `docs/开发笔记.md`。

---

## 结构

Godot 4.7（GDScript），联网走 ENet（UDP），只跑局域网，没有在线服务。

代码分三层，依赖是单向的：游戏层认识框架层，框架层不认识任何具体游戏。

```
games/      游戏层    每款游戏实现同一个 MiniGame 接口
core/       框架层    连接、房间、游戏注册表、通用 UI 主题
drawing/    绘制引擎  你画我猜与画猜接龙共用的画板
```

跑测试：`tools\run_tests.ps1`，几秒钟完事。联机那几套要起多个进程，在 `tools\tests\` 下单独跑。

---

## 文档

| 文档 | 内容 |
|---|---|
| [`聚会游戏项目规划.md`](聚会游戏项目规划.md) | 完整产品规划：玩法设计、联网架构、排期、风险与上线指标 |
| [`docs/开发笔记.md`](docs/开发笔记.md) | 工程实践中的坑与结论 |
| [`docs/workflow.md`](docs/workflow.md) | 多分支并行开发的流程说明 |
| [`docs/环游中国（大富翁玩法）规划.md`](docs/环游中国（大富翁玩法）规划.md) | 环游中国的设计文档：40 格中国城市棋盘、规则取舍、竖屏界面与技术拆分 |
| [`AGENTS.md`](AGENTS.md) | 协作与代码约定 |

---

## 许可

MIT License，见 [LICENSE](LICENSE)。

任何人可以自由使用、修改、分发这份代码（包括商用），只要保留版权声明。
