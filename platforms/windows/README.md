# Windows / 小狼毫实现

本目录是当前可用的平台实现，支持 64 位 Windows、小狼毫和全拼。

## 目录

```text
windows/
├─ src/CloudPinyinAsyncHelper.cs
├─ lua/cloud_pinyin_async.lua
├─ examples/rime_frost.custom.yaml
├─ build.ps1
└─ README.md
```

## 工作方式

- Lua processor 监听 Rime context，并把请求写到用户目录。
- C# helper 在 Weasel 进程之外完成防抖和并发 HTTP。
- 搜狗或 Google 每完成一路，就发布新的响应 revision。
- helper 仅在前台窗口仍相同时注入私有 `F24`；Lua 吞掉该事件并刷新候选。
- 用户上屏后，Lua 显式调用 `Memory:update_userdict`。
- 与本地词典、用户词或大模型候选同文时，保留非云版本；首轮双源完成后自动扩大候选池补查一次。

完整时序见 [`../../docs/architecture.md`](../../docs/architecture.md)。

## 要求

- 64 位 Windows 10/11。
- 小狼毫，且包含 librime-lua。
- 源码构建需要 Windows 的 .NET Framework 4.x C# 编译器。

当前已在 Weasel 0.17.4 / librime 1.13.1 验证。

## 构建

从仓库根目录执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\platforms\windows\build.ps1
```

输出：

```text
platforms/windows/dist/cloud_pinyin_async_helper.exe
```

也可以指定输出路径：

```powershell
.\platforms\windows\build.ps1 -OutputPath 'C:\Temp\cloud_pinyin_async_helper.exe'
```

## 安装

先确定小狼毫实际用户目录。默认通常是 `%APPDATA%\Rime`；设置过自定义目录时，应读取 `HKCU\Software\Rime\Weasel` 的 `RimeUserDir`。

最终文件结构：

```text
<Rime 用户目录>/
├─ cloud_pinyin_async_helper.exe
└─ lua/
   └─ cloud_pinyin_async.lua
```

对应源文件：

- helper：`platforms/windows/dist/cloud_pinyin_async_helper.exe`
- Lua：`platforms/windows/lua/cloud_pinyin_async.lua`

## 白霜配置：第 3 位开始、最多 5 个

参考 [`examples/rime_frost.custom.yaml`](examples/rime_frost.custom.yaml)，把以下内容合并到 `rime_frost.custom.yaml` 的 `patch:`：

```yaml
patch:
  "engine/processors/@before 0": lua_processor@*cloud_pinyin_async*processor
  "engine/translators/@before last": lua_translator@*cloud_pinyin_async*translator
  "engine/filters/@next": lua_filter@*cloud_pinyin_async*filter

  cloud_pinyin_async:
    delay_ms: 500
    timeout_ms: 1200
    candidates_per_source: 5
    max_candidates: 5
    insert_after: 2
    min_input_length: 2
    learn_to_user_dict: true
    refill_on_duplicate: true
    refill_delay_ms: 100
    refill_candidates_per_source: 10
    refill_max_candidates: 20
```

cloud filter 应位于方案原有的 `uniquifier` 之后。`insert_after: 2` 先输出两个本地候选，因此云候选从第 3 位开始；`max_candidates: 5` 是两个来源去重合并后的总上限。

如果某个云候选已由本地词典、用户词库或大模型给出，filter 会保留非云版本并过滤带 `☁` 的版本。首轮搜狗和 Google 都结束后，只要发生过这种过滤，就用更大的候选池补查一次，尽量把 5 个云候选补满；扩大后仍不足时不再请求。

修改后重新部署小狼毫，并在 `build/rime_frost.schema.yaml` 中确认三个组件和参数已经生效。

## 第 1 位模式

如需云候选直接进入菜单前部，不挂载 cloud filter：

```yaml
patch:
  "engine/processors/@before 0": lua_processor@*cloud_pinyin_async*processor
  "engine/translators/@before last": lua_translator@*cloud_pinyin_async*translator
  # 不配置 engine/filters 中的 cloud_pinyin_async filter
```

此时 `insert_after` 不参与排序。即使在 filter 模式把它设为 `0`，当前过滤器也需要先读取一个本地候选，不能做到绝对第 1 位。

## 参数

| 配置项 | 默认值 | 说明 |
|---|---:|---|
| `delay_ms` | `500` | 输入停止多久后开始联网 |
| `timeout_ms` | `900` | 每个云源的请求超时 |
| `candidates_per_source` | `5` | 每个来源最多读取多少候选 |
| `max_candidates` | `8` | 两个来源去重合并后的总上限 |
| `insert_after` | `3` | 仅挂载 filter 时，先输出多少个本地候选 |
| `min_input_length` | `2` | 触发查询的最短输入长度 |
| `learn_to_user_dict` | `true` | 云候选上屏后是否写入当前方案用户词库 |
| `refill_on_duplicate` | `true` | 过滤本地/大模型重复项后是否补查一次 |
| `refill_delay_ms` | `100` | 补查防抖时间 |
| `refill_candidates_per_source` | `10` | 补查时每个来源最多解析多少候选 |
| `refill_max_candidates` | `20` | 补查合并池上限，最终显示仍受 `max_candidates` 限制 |

## 进程生命周期

helper 是当前 Windows 会话中的常驻单例：

- 方案初始化时启动；写请求时也会检查并按需补拉起。
- session-local mutex 防止重复实例。
- 每 20 ms 检查请求文件，每 2 秒更新心跳。
- 心跳 6 秒未更新即视为失效，Lua 下次请求时重新启动。
- 当前没有空闲退出；关闭小狼毫后 helper 仍可能驻留。

详见 [`../../docs/architecture.md`](../../docs/architecture.md)。

## 运行时文件

helper 会在 Rime 用户目录生成：

```text
cloud_pinyin_async.request
cloud_pinyin_async.response
cloud_pinyin_async.heartbeat
cloud_pinyin_async.log
```

它们已被 `.gitignore` 排除。helper 未运行时可以删除，下次启动会重新创建。

## 验收

1. 输入本地词库不易命中的全拼并停止 500 ms。
2. 确认前两个位置为本地候选，云候选从第 3 位开始且不超过 5 个。
3. 确认能看到 `☁搜`、`☁谷` 或 `☁搜谷`。
4. 在网络请求期间继续输入，确认没有按键卡顿。
5. 快速修改输入，确认旧拼音结果不会进入新菜单。
6. 选中云候选后重复输入，确认用户词库已经记忆。
7. 用本地或大模型已经能给出的词测试，确认只显示非云版本；日志出现一次 `duplicate refill requested`，随后最多仍显示 5 个纯云新增候选。

## 故障排查

- 完全没有云候选：检查 exe 与 Lua 安装位置，以及 `cloud_pinyin_async.log`。
- 配置没有变化：检查最终生成的 `build/<方案>.schema.yaml`。
- 只有一个来源：另一端点可能超时或临时失效，本地输入不受影响。
- 双拼不触发：这是当前限制，Windows 实现只接受全拼。
- helper 存活但无响应：结束该 helper，下一次输入会在心跳过期后重新拉起。
