# Rime Cloud Pinyin Async

给 Windows 小狼毫使用的非阻塞云拼音扩展。用户停止输入一小段时间后，扩展同时查询搜狗和 Google Input Tools；先返回的来源先进入当前候选菜单，另一路随后完成时再合并。网络请求全部运行在小狼毫进程之外，超时或断网不会阻塞正常按键处理。

当前实现只支持 Windows + 小狼毫 + 全拼。macOS 鼠须管后端尚未完成，详见[跨平台状态](#跨平台状态)。

## 特性

- 默认停止输入 `500 ms` 后自动查询；只有已经出现全拼候选菜单时才触发。
- 搜狗与 Google 并发请求，不等待较慢来源；候选标记为 `☁搜`、`☁谷` 或 `☁搜谷`。
- 进程外网络 I/O：Lua 不执行 HTTP，请求期间可继续输入、翻页和选词。
- 以请求编号、当前输入串、活动窗口和候选菜单状态丢弃过期结果。
- 云候选上屏后显式调用 `Memory:update_userdict` 写入当前方案的正常用户词库。
- 可通过配置控制防抖时间、超时、单源数量、合并上限、插入位置和是否学习。
- 任一云源失败时静默降级；本地候选不依赖网络。

## 工作方式

1. Lua processor 监听输入上下文，只接受带 `abc` 标签、已有候选菜单且由 `a-z`/撇号组成的全拼。
2. Lua 将小型请求状态写入 Rime 用户目录，Windows helper 在独立进程中完成 `500 ms` 防抖。
3. helper 并发查询搜狗和 Google。每完成一路就写一个新的响应 revision，并向当前应用发送私有 `F24` 刷新事件。
4. Lua processor 吞掉该事件，验证请求仍然有效后刷新组句；translator 产出云候选。
5. 用户选择云候选后，commit notifier 按实际上屏文本确认选择，再显式写入用户词库。

这里的“写入用户词库”不是 Lua 候选的默认行为。扩展专门调用 librime-lua 的 `Memory:update_userdict`，因此 Space、数字键和鼠标上屏都能被记录。

## 安装（Windows）

要求：

- 小狼毫，且包含 librime-lua；当前已在 Weasel 0.17.4 / librime 1.13.1 验证。
- 64 位 Windows。
- 编译源码时需要 Windows 自带的 .NET Framework 4.x C# 编译器。

先构建 helper：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\build.ps1
```

然后复制文件：

```text
<Rime 用户目录>/
├─ cloud_pinyin_async_helper.exe
└─ lua/
   └─ cloud_pinyin_async.lua
```

Rime 用户目录通常是 `%APPDATA%\Rime`；如果小狼毫设置过自定义用户目录，应以注册表 `HKCU\Software\Rime\Weasel` 的 `RimeUserDir` 为准。

### 白霜拼音：从第 3 位开始、最多 5 个

把以下内容合并到 `rime_frost.custom.yaml` 的 `patch:` 中，或直接参考 [`examples/rime_frost.custom.yaml`](examples/rime_frost.custom.yaml)：

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
```

cloud filter 应放在方案原有的 `uniquifier` 之后。`insert_after: 2` 先输出两个本地候选，因此云候选从菜单第 3 位开始；`max_candidates: 5` 保证搜狗和 Google 去重合并后最多产出 5 个云候选。过滤器还会在云词已经学入用户词库时优先保留本地 `user_phrase` 版本。

### 从第 1 位开始

如需让云候选直接进入菜单最前部，删除 cloud filter 的挂载：

```yaml
patch:
  "engine/processors/@before 0": lua_processor@*cloud_pinyin_async*processor
  "engine/translators/@before last": lua_translator@*cloud_pinyin_async*translator
  # 不挂载 lua_filter@*cloud_pinyin_async*filter
```

如果该挂载只存在于 custom 文件中，直接删掉对应行即可，不必添加 `null`。没有 cloud filter 时，云 translator 的候选按高权重进入菜单前部，`insert_after` 不再参与排序。由于当前过滤器需要先读取一个候选才能建立输出流，即使把 `insert_after` 设为 `0`，也只能排在第一个本地候选之后；要求绝对第 1 位时必须不挂载过滤器。

修改配置后重新部署小狼毫。

## 配置

| 配置项 | 默认值 | 说明 |
|---|---:|---|
| `delay_ms` | `500` | 输入停止多久后开始联网 |
| `timeout_ms` | `900` | 每个云源的请求超时 |
| `candidates_per_source` | `5` | 每个来源最多读取多少候选 |
| `max_candidates` | `8` | 两个来源去重合并后的总上限 |
| `insert_after` | `3` | 仅挂载 filter 时，在多少个本地候选后插入 |
| `min_input_length` | `2` | 触发查询的最短输入长度 |
| `learn_to_user_dict` | `true` | 云候选上屏后是否写入当前方案用户词库 |

`candidates_per_source` 控制单源抓取量，`max_candidates` 才是每一轮最终显示的云候选总数。第二个来源到达后会重新去重并受同一个总上限约束。

## 网络与隐私

启用后，符合条件的当前全拼串会自动发送到两个第三方 Web 端点：

- 搜狗移动 Web 输入接口；
- Google Input Tools 请求接口。

这些端点无需 key，但不是面向本项目承诺稳定性的正式 API，可能随时改变、限流或失效。不要把密码、令牌等敏感内容放在中文拼音组句状态中。helper 日志只记录请求长度、耗时和状态，不记录查询内容；被选择的云词会按功能设计保存在本机 Rime 用户词库中。

运行时会在 Rime 用户目录产生以下状态文件：

```text
cloud_pinyin_async.request
cloud_pinyin_async.response
cloud_pinyin_async.heartbeat
cloud_pinyin_async.log
```

它们不应提交到 Git。helper 未运行时可以删除，下次启动会重新创建。

## 跨平台状态

当前 Lua 和 provider 协议可以作为 macOS 移植的基础，但 Windows helper 依赖 `user32.dll`、前台窗口枚举和 `F24` 注入，不能在鼠须管上直接运行。

macOS 版本至少需要替换两层：

1. 将双源网络请求、文件协议和防抖逻辑移植为 macOS 可运行的后台 helper；
2. 找到鼠须管能够安全触发当前 Rime context 重组候选菜单的异步通知方式，替换 Windows 的 `F24` 刷新通道。

在这两项完成并实测前，本仓库不会宣称 macOS 可用。网络请求仍应保持在 Rime 主进程之外，避免退回阻塞式 `curl` Lua 调用。

## 故障排查

- 完全没有云候选：确认 exe 位于 Rime 用户目录根部、Lua 位于 `lua/`，并检查 `cloud_pinyin_async.log`。
- 只有一个来源：另一个端点可能超时或临时失效；本地输入不受影响。
- 配置改了但没变化：查看 `build/<方案>.schema.yaml` 是否已经包含组件和新参数。
- 云词上屏后不记忆：确认 `learn_to_user_dict: true`，并检查当前方案本身是否启用了用户词库。
- 双拼不触发：这是当前限制；本实现只接受全拼输入。

## 致谢

- [rime-wenyun](https://github.com/xing133/rime-wenyun)：搜狗协议研究、云词记忆实践与项目思路参考。
- [librime-cloud](https://github.com/hchunhui/librime-cloud)：Rime 云输入的早期实现。
- [librime-lua](https://github.com/hchunhui/librime-lua)：Lua 扩展接口。

第三方许可说明见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## License

[MIT](LICENSE)
