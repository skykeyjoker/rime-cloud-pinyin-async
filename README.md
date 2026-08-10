# Rime Cloud Pinyin Async

为 Rime 提供进程外、非阻塞的双源云拼音。用户停止输入一小段时间后，平台 helper 并发查询搜狗和 Google Input Tools；先返回的来源先进入候选菜单，另一来源随后合并。网络超时、断网和过期结果不会阻塞正常按键处理。

> 当前可用版本：Windows 小狼毫全拼、macOS Fcitx5-Mac 全拼、macOS 鼠须管全拼。

## 平台状态

| 平台 | 前端 | 状态 | 实现目录 |
|---|---|---|---|
| Windows x64 | 小狼毫 Weasel | 可用，已在 Weasel 0.17.4 / librime 1.13.1 验证 | [`platforms/windows`](platforms/windows/README.md) |
| macOS arm64 | Fcitx5-Mac | 可用，已在 Fcitx5-Mac 0.3.4 / fcitx5 5.1.21 验证 | [`platforms/macos/fcitx5`](platforms/macos/fcitx5/README.md) |
| macOS arm64 | 鼠须管 Squirrel | 可用，已在 `rime/squirrel@1dde02217f11` / librime 1.17.0 验证 | [`platforms/macos/squirrel`](platforms/macos/squirrel/README.md) |

## 设计目标

- HTTP 永远不在 Rime/Lua 主线程执行。
- 搜狗和 Google 并发请求，先到结果不等待慢来源。
- 输入变化、窗口变化或候选选择变化后，旧结果不能污染当前菜单。
- 平台实现共享同一套配置语义、文件协议、来源标记和验收标准。
- 云候选上屏后明确写入当前方案用户词库，而不是依赖 Lua 候选的隐式学习。
- 云候选与本地词典、用户词或大模型候选同文时保留非云版本，并用一次扩大候选池的补查尽量补满显示数量。
- 任一平台未达到非阻塞要求前，不标记为可用。

## 仓库结构

```text
.
├─ docs/
│  ├─ architecture.md          # 组件边界、请求时序和生命周期
│  └─ file-protocol-v1.md      # Lua 与 helper 的跨进程协议
├─ platforms/
│  ├─ windows/
│  │  ├─ src/                  # Windows helper 源码
│  │  ├─ lua/                  # 小狼毫 Lua 组件
│  │  ├─ examples/             # 白霜配置示例
│  │  ├─ build.ps1
│  │  └─ README.md
│  └─ macos/
│     ├─ common/               # 两个 macOS 前端共享的 Swift helper 与 Lua
│     ├─ fcitx5/               # Fcitx5 addon、构建和安装说明
│     ├─ squirrel/             # 鼠须管补丁、构建和安装说明
│     └─ README.md
├─ LICENSE
└─ THIRD_PARTY_NOTICES.md
```

Windows 使用独立的 C# helper；Fcitx5-Mac 与鼠须管共享 macOS Swift helper 和 Lua，只分别实现前端安全刷新通道。真正跨操作系统且稳定的边界仍固化为 [`docs/file-protocol-v1.md`](docs/file-protocol-v1.md)。

## Windows 快速开始

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\platforms\windows\build.ps1
```

随后按 [`platforms/windows/README.md`](platforms/windows/README.md) 将 helper、Lua 文件和配置安装到小狼毫用户目录。

## Fcitx5-Mac 快速开始

```bash
git clone --recurse-submodules https://github.com/fcitx-contrib/fcitx5-macos.git ../fcitx5-macos-source
FCITX5_SOURCE=../fcitx5-macos-source/fcitx5 ./platforms/macos/fcitx5/build.sh
```

Fcitx5 插件必须和已安装应用使用兼容的 fcitx5 ABI。构建完成后，按 [`platforms/macos/fcitx5/README.md`](platforms/macos/fcitx5/README.md) 安装 Swift helper、Lua、刷新插件和白霜配置补丁。

## 鼠须管快速开始

```bash
git clone --recurse-submodules https://github.com/rime/squirrel.git ../squirrel
git -C ../squirrel checkout 1dde02217f11
git -C ../squirrel submodule update --init --recursive
./platforms/macos/squirrel/apply-squirrel-patch.sh ../squirrel
SQUIRREL_SOURCE=../squirrel ./platforms/macos/squirrel/build.sh
```

鼠须管需要重新构建带安全刷新通道的前端；不能只复制 Lua 和 helper。完整备份、签名与安装步骤见 [`platforms/macos/squirrel/README.md`](platforms/macos/squirrel/README.md)。

本仓库的白霜示例默认：

- Windows 停止输入 `500 ms` 后查询，两个 macOS 前端为 `300 ms`；
- 搜狗、Google 各取最多 5 个；
- 去重合并后最多显示 5 个云候选；
- 前两个位置保留本地候选，云候选从第 3 位开始；
- 选中云候选后写入 `rime_frost.userdb`。
- 首轮云候选与本地/大模型重复而不足 5 个时，再并发补查一次（每源 10、合并池 20），过滤后仍最多显示 5 个。

## 跨平台契约

平台实现可以使用不同语言和唤醒机制，但必须保持以下可观察行为：

1. `delay_ms` 防抖期间的新输入覆盖旧请求；
2. 两个 provider 并发，第一份有效结果立即发布；
3. 每次发布带单调递增 revision；
4. Lua 同时核对请求编号和当前输入，拒绝过期响应；
5. `max_candidates` 是双源去重后的总上限；
6. 来源标记保持为 `☁搜`、`☁谷`、`☁搜谷`；
7. 用户词学习在本地完成，helper 不接触 Rime 用户数据库。
8. 补查最多一轮，且只有首轮双源均结束、确实过滤了本地/大模型重复项时触发。

详细边界见 [`docs/architecture.md`](docs/architecture.md)。

## 网络与隐私

启用后，符合条件的当前全拼串会自动发送到搜狗移动 Web 输入接口和 Google Input Tools。这两个端点无需 key，但不是面向本项目承诺稳定性的正式 API，可能改变、限流或失效。

helper 日志只记录请求长度、耗时和状态，不记录查询内容；被选择的云词会按功能设计保存在本机 Rime 用户词库中。请求、响应、心跳和日志均为运行时文件，不进入 Git。

## macOS 前端说明

macOS 共享组件位于 [`platforms/macos/common`](platforms/macos/common/README.md)。Fcitx5-Mac 使用进程内 addon 观察响应文件；鼠须管使用目录限定的分布式通知并直接刷新当前 librime session。两种实现都只在输入法引擎内部消费私有 F24，不生成系统级按键，详见 [`platforms/macos`](platforms/macos/README.md)。

## 致谢与许可

- [rime-wenyun](https://github.com/xing133/rime-wenyun)：搜狗协议研究、云词记忆实践与项目思路参考。
- [librime-cloud](https://github.com/hchunhui/librime-cloud)：Rime 云输入的早期实现。
- [librime-lua](https://github.com/hchunhui/librime-lua)：Lua 扩展接口。

除鼠须管源码补丁外，本项目采用 [MIT License](LICENSE)。`platforms/macos/squirrel/patches/` 随上游鼠须管按 GPL-3.0 分发，详见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
