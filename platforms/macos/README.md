# macOS 实现

macOS 下的 Fcitx5-Mac 与鼠须管共享同一套进程外网络 helper、文件协议和 Lua 候选逻辑，并分别实现安全的前端刷新通道。

## 目录

```text
macos/
├─ common/                 # Swift helper 与共享 Lua
├─ fcitx5/                 # Fcitx5 进程内刷新 addon、构建与安装说明
└─ squirrel/               # 鼠须管源码补丁、构建与安装说明
```

| 前端 | 刷新机制 | 状态 | 文档 |
|---|---|---|---|
| Fcitx5-Mac | addon 观察响应文件并直接向当前 Rime 引擎投递私有 F24 | 可用 | [`fcitx5`](fcitx5/README.md) |
| 鼠须管 Squirrel | helper 发布目录限定通知，鼠须管在主线程刷新当前 librime session | 可用 | [`squirrel`](squirrel/README.md) |

两套实现均不生成全局键盘事件、不要求辅助功能权限，也不在 Lua 主线程进行 HTTP 请求。共享实现见 [`common`](common/README.md)，跨进程文件格式见 [`../../docs/file-protocol-v1.md`](../../docs/file-protocol-v1.md)。

## 快速入口

Fcitx5-Mac：

```bash
FCITX5_SOURCE=../fcitx5-macos-source/fcitx5 ./platforms/macos/fcitx5/build.sh
```

鼠须管：

```bash
./platforms/macos/squirrel/apply-squirrel-patch.sh ../squirrel
SQUIRREL_SOURCE=../squirrel ./platforms/macos/squirrel/build.sh
```

两个前端会使用各自的 Rime 用户目录。请先备份现有配置，再安装共享 Lua、helper 和对应前端的刷新组件，并将各自 `examples/rime_frost.custom.yaml` 合并到当前方案。
