# 文件协议 RIME_CLOUD_V1

本文定义 Lua 组件与平台 helper 之间的最小跨进程协议。Windows 小狼毫、macOS Fcitx5-Mac 与 macOS 鼠须管均已实现；其他前端移植时应优先保持兼容，只有无法表达新平台需求时才升级 magic/version。

## 文件位置

所有文件位于当前 Rime 用户目录：

```text
cloud_pinyin_async.request
cloud_pinyin_async.response
cloud_pinyin_async.heartbeat
cloud_pinyin_async.log
```

这些文件包含运行时状态，不得提交 Git。helper 以 Rime 用户目录绝对路径作为第一个启动参数。

## 编码和分隔

- 文本编码：UTF-8，无 BOM。
- 行分隔：读取方必须同时接受 LF 和 CRLF。
- 字段分隔：水平制表符 `TAB`。
- 请求中的输入仅允许小写 `a-z` 和撇号，因此不需要额外转义。
- 响应候选文本和拼音使用 Base64 包装，避免 TAB、换行和 Unicode 造成歧义。

## 请求文件

请求为一行七个字段：

```text
request_id<TAB>context_input<TAB>query_input<TAB>delay_ms<TAB>timeout_ms<TAB>candidates_per_source<TAB>max_candidates
```

| 序号 | 字段 | 说明 |
|---:|---|---|
| 1 | `request_id` | 当前 Rime engine/session 内唯一且单调变化的请求标识 |
| 2 | `context_input` | Rime context 中的完整原始全拼输入，可含撇号；分段选词后仍保持完整，用于拒绝过期响应 |
| 3 | `query_input` | 当前尚未确认的 `abc` segment，发送 provider 前去掉撇号 |
| 4 | `delay_ms` | 防抖时间 |
| 5 | `timeout_ms` | 单 provider 参与当前请求的硬截止时间 |
| 6 | `candidates_per_source` | 单来源候选上限 |
| 7 | `max_candidates` | 双源去重后的总上限 |

空的 `query_input` 表示当前 context 已不适合显示云候选。helper 应清空响应并取消 pending 状态；已经发出的网络任务可以继续结束，但不得再发布该请求。

分段选词时，Rime 会推进当前 segment，但不一定改变 `context_input` 或触发普通输入更新。Lua 因此同时使用完整输入、segment 范围和 `query_input` 标识请求，并在候选确认后主动调度剩余 segment；响应必须同时匹配请求编号、完整输入和剩余查询才可显示。

Windows 与 macOS 共享 helper 都对数值执行以下防御性约束：

- `delay_ms`: 100–3000
- `timeout_ms`: 200–5000
- `candidates_per_source`: 1–10
- `max_candidates`: 1–20

协议中的超时约束候选是否还能发布，不要求底层网络 API 已经终止。Windows 会在
截止时关闭当前请求并忽略迟到结果；每个来源使用单 worker 和单 pending 槽，即使
操作系统 DNS 调用晚于截止返回，也不会阻塞心跳或形成无界任务积压。

### 补查仍使用 V1 请求

过滤器发现云候选与本地词典、用户词或大模型候选同文后，不需要新增协议字段。首轮双源都完成时，Lua 使用新的 `request_id` 再写一条 V1 请求，并提高 `candidates_per_source` 与 `max_candidates`。当前各平台的默认补查值均为每源 10、合并池 20，防抖 100 ms。

补查请求编号包含 `-refill-`，同一输入最多补查一次。这里的较大 `max_candidates` 只控制 helper 返回池；Lua filter 仍按方案配置的显示上限截断。

## 响应文件

第一行为九字段 header：

```text
RIME_CLOUD_V1<TAB>request_id<TAB>context_input<TAB>query_input<TAB>revision<TAB>sogou_ms<TAB>google_ms<TAB>sogou_status<TAB>google_status
```

后续每个候选一行：

```text
C<TAB>base64_utf8_text<TAB>base64_utf8_pinyin<TAB>source_code
```

`source_code`：

| 值 | 含义 | UI 标记 |
|---|---|---|
| `SG` | 仅搜狗返回 | `☁搜` |
| `GG` | 仅 Google 返回 | `☁谷` |
| `SG+GG` | 两个来源返回同一文本 | `☁搜谷` |

同一请求每次实际候选集合变化时 revision 加一。常见流程是第一个来源产生 revision 1，第二来源合并后产生 revision 2；如果第二来源没有带来新文本或来源变化，可以不发布新 revision。

Lua 必须同时验证：

- magic 为 `RIME_CLOUD_V1`；
- `request_id` 等于 context 当前请求属性；
- `context_input` 等于当前输入；
- revision/token 尚未被消费或确实需要刷新。

## 心跳

`cloud_pinyin_async.heartbeat` 只包含 UTC Unix epoch 秒数：

```text
1786290000
```

当前各平台 Lua 都将时间差不超过 6 秒视为 helper 存活，helper 每 2 秒更新一次。其他平台可以调整内部写入方式，但在共享 Lua 之前必须保持相同语义。

## 日志

日志不是协议正确性的一部分。建议只记录：

- helper 启停和 PID；
- 请求编号及输入长度；
- provider 状态、耗时和候选数量；
- 过期、前台变化、刷新抑制等原因。

不得记录完整查询输入、候选正文、用户词库内容或凭据。

## 平台刷新通道

刷新通知不属于文件格式，但属于完整实现：

- Windows 当前在确认前台窗口未改变后发送私有 `F24`，Lua processor 吞掉该键并刷新未确认组句。
- Fcitx5-Mac addon 每 25 ms 检查响应文件；只有当前聚焦输入上下文正在使用 Rime 时，才把私有 `F24` 直接投递给该输入法引擎。事件不会进入 macOS 按键流，Lua processor 负责吞掉并刷新未确认组句。
- macOS helper 每次成功写入新 revision 后还会发布 `SquirrelCloudPinyinResponseReadyNotification`，通知对象是标准化后的 Rime 用户目录。鼠须管只监听自己的目录，在主线程确认当前 client 和 librime session 有效后，直接把私有 `F24` 交给当前引擎；不会生成系统级按键。

不论平台使用何种机制，文件中的请求编号和当前 Rime context 校验仍是最终安全边界。
