# 冻结契约变更请求

`games/base_minigame.gd`、`core/net/protocol.gd`、`core/net/transport.gd`、`drawing/board.gd`
是并行开发的基础，已冻结。任何 agent 认为必须修改时，**不要直接改**，
在下面追加一条记录，由 root agent 统一裁决后再统一修改。

格式：

```
## [待裁决] <文件> · <一句话标题>
- 提出者：
- 分支：
- 需要改成什么：
- 为什么现有接口不够用：
- 如果改了，会影响谁：
```

---

（暂无记录）
