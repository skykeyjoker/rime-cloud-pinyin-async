# Rime Cloud Pinyin Async

为 Rime 提供非阻塞的双源云拼音候选，支持 Windows 小狼毫和 macOS。

当用户停止输入一小段时间后，独立 helper 会并发查询搜狗和 Google Input Tools。先返回的来源可以先显示，另一路随后合并；断网、超时或过期响应不会阻塞本地输入。

> [!IMPORTANT]
> 启用后，当前尚未上屏的全拼编码会通过网络发送给搜狗和 Google。介意第三方服务接收输入编码时，请不要启用。完整说明见[隐私说明](#隐私说明)。

## 功能特点

- 网络请求在 Rime 前端进程之外执行，不阻塞按键和本地候选。
- 搜狗与 Google 并发请求，先到结果无需等待另一来源。
- 云候选显示来源标记：`☁搜`、`☁谷` 或 `☁搜谷`。
- 输入、窗口或候选选择发生变化后，旧结果会被丢弃。
- 本地词典、用户词和万象等模型候选优先于同文云候选。
- 选中的云候选可以写入当前方案的 Rime 用户词典。
- 单一云源超时或失效时，另一来源和本地输入仍可继续工作。

当前只验证了**全拼**。双拼及其他编码方案不在支持范围内；仓库示例以[白霜拼音](https://github.com/gaboolic/rime-frost)为准。

## 选择适合的平台

| 系统 | 前端 | 推荐程度 | 已验证环境 | 说明 |
|---|---|---|---|---|
| macOS 13.3+（Apple Silicon） | **Fcitx5-Mac** | **Mac 首选** | Fcitx5-Mac 0.3.4 / fcitx5 5.1.21 | 不修改 Fcitx5-Mac 官方应用源码，只额外安装 helper、Lua 和刷新 addon |
| Windows x64 | 小狼毫 Weasel | Windows 首选 | Weasel 0.17.4 / librime 1.13.1 | 使用独立 C# helper，无需修改小狼毫源码 |
| macOS 13.3+（Apple Silicon） | 鼠须管 Squirrel | 高级方案 | `rime/squirrel@1dde02217f11` / librime 1.17.0 | 必须 patch 官方 Swift 源码、重新编译并签名鼠须管 |

仓库当前提供源码和构建脚本，不提供跨版本通用安装包。macOS Intel、Windows ARM 以及表格之外的前端尚未验证。

### 为什么 Mac 优先推荐 Fcitx5-Mac

Fcitx5-Mac 的适配只增加一个进程外 helper、共享 Lua 和进程内刷新 addon，不需要替换或维护一份修改过的输入法应用。升级 Fcitx5-Mac 后，通常只需要使用匹配版本的 fcitx5 源码重新构建 addon。

鼠须管方案会修改官方前端的两个 Swift 文件，还需要自行构建、签名和替换 `Squirrel.app`。上游相关代码变化后，补丁可能无法继续应用，官方自动更新也可能覆盖本地版本。**如果没有必须使用鼠须管的理由，建议选择 Fcitx5-Mac。**

## 安装前准备

1. 备份当前 Rime 用户目录、用户词典和自定义 YAML。
2. 确认正在使用包含 `librime-lua` 的 Rime 前端。
3. 确认输入方案为全拼；其他方案即使能部署，也不代表云查询编码正确。
4. 克隆本仓库：

   ```bash
   git clone https://github.com/skykeyjoker/rime-cloud-pinyin-async.git
   cd rime-cloud-pinyin-async
   ```

不要直接覆盖已有的 `rime_frost.custom.yaml`。已有自定义配置时，应合并示例中的 `patch` 项。

## macOS 安装：Fcitx5-Mac（推荐）

完整平台说明见 [`platforms/macos/fcitx5`](platforms/macos/fcitx5/README.md)。

### 1. 准备依赖

- 已安装 [Fcitx5-Mac](https://github.com/fcitx-contrib/fcitx5-macos)，默认位于 `/Library/Input Methods/Fcitx5.app`；
- 已安装 Xcode Command Line Tools；
- 准备与已安装 Fcitx5-Mac ABI 匹配的 fcitx5 源码。

```bash
xcode-select --install
git clone --recurse-submodules https://github.com/fcitx-contrib/fcitx5-macos.git ../fcitx5-macos-source
```

如果本机安装的不是上游最新版本，请先把 `../fcitx5-macos-source` 切换到对应 tag 或 commit，再继续构建。

### 2. 构建

```bash
FCITX5_SOURCE=../fcitx5-macos-source/fcitx5 \
  ./platforms/macos/fcitx5/build.sh
```

构建成功后会生成：

```text
platforms/macos/fcitx5/dist/cloud_pinyin_async_helper
platforms/macos/fcitx5/dist/libcloudpinyinrefresh.so
```

如果 Fcitx5-Mac 不在默认位置，可通过 `FCITX5_APP_CONTENTS` 指定其 `Contents` 目录。

### 3. 安装文件

```bash
mkdir -p ~/.local/share/fcitx5/rime/lua
mkdir -p ~/Library/fcitx5/lib/fcitx5
mkdir -p ~/Library/fcitx5/share/fcitx5/addon

install -m 0644 platforms/macos/common/lua/cloud_pinyin_async.lua \
  ~/.local/share/fcitx5/rime/lua/
install -m 0755 platforms/macos/fcitx5/dist/cloud_pinyin_async_helper \
  ~/.local/share/fcitx5/rime/
install -m 0755 platforms/macos/fcitx5/dist/libcloudpinyinrefresh.so \
  ~/Library/fcitx5/lib/fcitx5/
install -m 0644 platforms/macos/fcitx5/fcitx-addon/cloudpinyinrefresh.conf \
  ~/Library/fcitx5/share/fcitx5/addon/
```

### 4. 启用白霜配置

配置示例：[`platforms/macos/fcitx5/examples/rime_frost.custom.yaml`](platforms/macos/fcitx5/examples/rime_frost.custom.yaml)

- 如果 `~/.local/share/fcitx5/rime/rime_frost.custom.yaml` 不存在，可以把示例复制为该文件；
- 如果文件已经存在，只合并示例里的三个 `engine` 组件和 `cloud_pinyin_async` 配置，不要覆盖原有主题、词库或按键设置。

仅当目标文件不存在时，可以直接复制：

```bash
if [[ ! -e ~/.local/share/fcitx5/rime/rime_frost.custom.yaml ]]; then
  cp platforms/macos/fcitx5/examples/rime_frost.custom.yaml \
    ~/.local/share/fcitx5/rime/rime_frost.custom.yaml
fi
```

在 Fcitx5 菜单中执行“重新部署”，然后正常退出并重新打开 Fcitx5。若菜单暂时为空，先切换到 ABC，再切回“小企鹅”。

## Windows 安装：小狼毫

完整平台说明见 [`platforms/windows`](platforms/windows/README.md)。

### 1. 构建 helper

要求 64 位 Windows 10/11、小狼毫和已启用的 .NET Framework 4.x。从仓库根目录打开 PowerShell：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\platforms\windows\build.ps1
```

输出文件为：

```text
platforms\windows\dist\cloud_pinyin_async_helper.exe
```

### 2. 安装文件

小狼毫默认用户目录通常是 `%APPDATA%\Rime`。如果注册表 `HKCU\Software\Rime\Weasel` 配置了 `RimeUserDir`，请把下方变量改为实际目录。

```powershell
$RimeUserDir = Join-Path $env:APPDATA 'Rime'
New-Item -ItemType Directory -Force (Join-Path $RimeUserDir 'lua') | Out-Null

Copy-Item .\platforms\windows\dist\cloud_pinyin_async_helper.exe $RimeUserDir
Copy-Item .\platforms\windows\lua\cloud_pinyin_async.lua (Join-Path $RimeUserDir 'lua')
```

### 3. 启用白霜配置

配置示例：[`platforms/windows/examples/rime_frost.custom.yaml`](platforms/windows/examples/rime_frost.custom.yaml)

将示例内容合并到小狼毫用户目录中的 `rime_frost.custom.yaml`，然后从小狼毫菜单执行“重新部署”。已有自定义文件时同样不要整文件覆盖。

仅当目标文件不存在时，可以直接复制：

```powershell
$TargetConfig = Join-Path $RimeUserDir 'rime_frost.custom.yaml'
if (-not (Test-Path $TargetConfig)) {
    Copy-Item .\platforms\windows\examples\rime_frost.custom.yaml $TargetConfig
}
```

## macOS 安装：鼠须管（高级方案）

> [!WARNING]
> 普通 Mac 用户不建议选择此方案。官方鼠须管无法只靠复制 Lua/helper 实现异步刷新；必须 patch 官方源码并维护自定义构建。

当前补丁只针对 `rime/squirrel@1dde02217f11` 验证：

```bash
git clone --recurse-submodules https://github.com/rime/squirrel.git ../squirrel
git -C ../squirrel checkout 1dde02217f11
git -C ../squirrel submodule update --init --recursive

./platforms/macos/squirrel/apply-squirrel-patch.sh ../squirrel
SQUIRREL_SOURCE=../squirrel \
CODE_SIGN_IDENTITY="Apple Development: your identity" \
  ./platforms/macos/squirrel/build.sh
```

安装前还需要确认签名、唯一 bundle ID、副本位置和自动更新策略。请严格按照 [`platforms/macos/squirrel/README.md`](platforms/macos/squirrel/README.md) 完成后续安装，不要直接用构建产物覆盖正在运行的官方应用。

## 使用与验证

默认白霜示例的行为如下：

| 行为 | Windows | macOS |
|---|---:|---:|
| 停止输入多久后联网 | 500 ms | 300 ms |
| 每个来源首轮最多读取 | 5 个 | 5 个 |
| 双源去重后最多显示 | 5 个 | 5 个 |
| 云候选插入位置 | 第 3 位开始 | 第 3 位开始 |

安装后可以这样验证：

1. 输入一个本地词库不容易命中的完整拼音，停止输入 0.5 秒左右。
2. 候选中出现 `☁搜`、`☁谷` 或 `☁搜谷`，表示云查询和异步刷新已经工作。
3. 网络请求期间继续输入，确认本地候选和按键没有卡顿。
4. 快速修改原始拼音，确认旧查询结果不会进入新的候选菜单。
5. 选择一个云候选后再次输入，检查候选排序是否体现用户词学习。

来源标记含义：

| 标记 | 含义 |
|---|---|
| `☁搜` | 仅搜狗返回该候选 |
| `☁谷` | 仅 Google 返回该候选 |
| `☁搜谷` | 两个来源都返回该候选 |

如果云候选与本地词典、用户词或万象模型候选同文，带云标记的版本会被过滤，并最多进行一轮扩大候选池的补查。

## 常用配置

以下参数位于 `rime_frost.custom.yaml` 的 `cloud_pinyin_async` 下：

| 参数 | 示例值 | 说明 |
|---|---:|---|
| `delay_ms` | `300` / `500` | 停止输入多久后开始联网 |
| `timeout_ms` | `1200` | 每个来源的超时时间 |
| `candidates_per_source` | `5` | 每个来源首轮最多读取多少候选 |
| `max_candidates` | `5` | 双源去重后的最终云候选上限 |
| `insert_after` | `2` | 先保留多少个本地候选 |
| `min_input_length` | `2` | 触发云查询的最短拼音长度 |
| `learn_to_user_dict` | `true` | 是否把选中的云候选写入用户词典 |
| `refill_on_duplicate` | `true` | 过滤同文本地/模型候选后是否补查一次 |

完整参数和排序模式见各平台 README。

## 隐私说明

### 会发送什么

- 达到 `min_input_length` 且通过防抖后，**当前尚未上屏的全拼编码**会分别通过 HTTPS 发送给搜狗移动 Web 输入接口和 Google Input Tools。
- 第三方服务会自然获得网络请求所包含的 IP 地址、时间和 User-Agent 等连接信息。
- 两个端点无需本项目提供账号或 API key，但它们不是为本项目承诺稳定性的正式 API，可能随时改变、限流或停止工作。

第三方如何处理数据不由本项目控制，使用前请阅读[搜狗输入法个人信息保护政策](https://shouji.sogou.com/wap/htmls/privacy_policy.html)和 [Google Privacy Policy](https://policies.google.com/privacy)。

### 本项目不会主动发送什么

- Rime 用户词典和本地词库文件；
- 已经上屏的正文、剪贴板内容或应用内其他文字；
- 本地候选列表、最终选择了哪个候选；
- 主题、按键配置或其他 Rime 文件；
- 任何项目自建统计、遥测或分析服务器数据。

### 本机保存什么

- Rime 用户目录会生成 request、response、heartbeat 和 log 等运行时文件；macOS 还会使用 lock，Fcitx5-Mac 另有刷新 bridge 状态。请求/响应文件会保留当前编码和云候选，直到被后续请求覆盖或由用户删除。
- helper 日志只记录请求编号、拼音长度、来源状态和耗时，不记录完整输入或候选正文。
- 开启 `learn_to_user_dict` 后，实际选中的云候选会写入当前方案的本地 Rime 用户词典。

输入编码本身也可能包含敏感信息。如果无法接受其被发送给第三方服务，请不要加载这三个 `cloud_pinyin_async` 组件。

## 停用与故障排查

要停用云拼音，从方案的 `engine/processors`、`engine/translators`、`engine/filters` 中移除对应的 `cloud_pinyin_async` 组件，并删除 `cloud_pinyin_async` 参数块，然后重新部署。停用方案后不会再生成新请求；helper 进程可能继续驻留，但不会自行查询。需要立即结束进程或完全卸载时，再按平台 README 删除已安装文件。

常见问题：

- **完全没有云候选**：确认 helper、Lua 和刷新组件安装位置，并检查最终生成的 `build/rime_frost.schema.yaml` 是否包含三个组件。
- **只有一个来源**：另一端点可能超时、限流或暂时失效，本地输入不受影响。
- **Fcitx5-Mac 升级后失效**：刷新 addon 与 fcitx5 ABI 相关，需要使用匹配源码重新构建。
- **鼠须管补丁无法应用**：不要模糊套用；切回已验证 commit，或重新审查上游变更后再移植补丁。
- **双拼没有云候选**：这是当前限制，不属于已支持场景。

日志位置和进一步排查步骤见 [Windows 文档](platforms/windows/README.md)、[Fcitx5-Mac 文档](platforms/macos/fcitx5/README.md)和[鼠须管文档](platforms/macos/squirrel/README.md)。

## 实现与开发文档

- [`docs/architecture.md`](docs/architecture.md)：组件边界、请求时序和生命周期；
- [`docs/file-protocol-v1.md`](docs/file-protocol-v1.md)：Lua 与 helper 的跨进程文件协议；
- [`platforms/windows`](platforms/windows/README.md)：Windows C# helper 与 Lua；
- [`platforms/macos/common`](platforms/macos/common/README.md)：macOS 共用 Swift helper 与 Lua；
- [`platforms/macos/fcitx5`](platforms/macos/fcitx5/README.md)：Fcitx5-Mac 刷新 addon；
- [`platforms/macos/squirrel`](platforms/macos/squirrel/README.md)：鼠须管源码补丁和构建流程。

平台实现虽然使用不同语言和唤醒机制，但共享相同的请求编号、revision、过期校验、来源标记、候选上限和本地学习语义。

## 致谢

- [Rime](https://rime.im/) 与 [librime](https://github.com/rime/librime)：输入法引擎与扩展基础；
- [librime-lua](https://github.com/hchunhui/librime-lua)：Lua 扩展接口；
- [rime-frost](https://github.com/gaboolic/rime-frost)：本仓库主要配置示例所适配的白霜拼音方案；
- [Fcitx 5](https://github.com/fcitx/fcitx5) 与 [Fcitx5-Mac](https://github.com/fcitx-contrib/fcitx5-macos)：macOS 推荐前端及刷新 addon 接口；
- [Weasel](https://github.com/rime/weasel)：Windows 小狼毫前端；
- [Squirrel](https://github.com/rime/squirrel)：macOS 鼠须管前端；
- [rime-wenyun](https://github.com/xing133/rime-wenyun)：搜狗协议研究、云词记忆实践与项目思路参考；
- [librime-cloud](https://github.com/hchunhui/librime-cloud)：Rime 云输入的早期实现；
- 搜狗和 Google Input Tools：云候选来源。

本项目是独立的社区实现，与搜狗或 Google 不存在隶属、授权或官方合作关系。

## 许可

除鼠须管源码补丁外，本项目采用 [MIT License](LICENSE)。

`platforms/macos/squirrel/patches/` 是针对 GPL-3.0 项目 Squirrel 的源码补丁，随上游按 GPL-3.0 分发；完整许可文本见 [`platforms/macos/squirrel/LICENSE.txt`](platforms/macos/squirrel/LICENSE.txt)。Fcitx 相关动态链接与其他第三方来源说明见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。第三方项目和服务仍适用各自的许可、服务条款与隐私政策。
