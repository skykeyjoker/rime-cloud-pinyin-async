# 架构与生命周期

## 组件边界

```text
┌──────────────────────── Rime 前端进程 ────────────────────────┐
│ processor：监听输入、校验刷新、捕获上屏                       │
│ translator：把有效响应转换为候选                              │
│ filter：可选，控制云候选插入位置并优先保留已学习的本地词       │
└───────────────────────┬──────────────────────────────────────┘
                        │ 请求/响应文件协议
                        │ + 平台专用刷新通知
┌───────────────────────▼──────────────────────────────────────┐
│ 平台 helper                                                  │
│ 防抖、并发 HTTP、来源合并、过期检查、响应 revision、心跳       │
└───────────────────┬───────────────────────┬──────────────────┘
                    │                       │
             搜狗移动 Web             Google Input Tools
```

网络请求必须位于 helper。Lua 负责 Rime context 和用户词库，因为只有它能可靠判断当前候选菜单以及调用 `Memory:update_userdict`。

## 一次请求的时序

1. 输入更新或候选确认后，processor 确认当前 context 正在组词、已有菜单、当前 segment 带 `abc` 标签且只包含全拼字符。
2. Lua 生成唯一请求编号，把完整 `context_input` 和当前尚未确认 segment 的 `query_input` 写入请求文件；不等待网络。
3. helper 观察到新请求并开始 `delay_ms` 防抖。期间出现新编号时直接替换 pending 请求。
4. 防抖完成后，helper 同时启动搜狗和 Google 查询。
5. 第一个来源完成后，helper 再次读取当前请求编号。仍有效才写 revision 1，并通过平台刷新通道通知前端。
6. Lua 收到通知后核对请求编号、输入、候选菜单和选择位置，全部一致才刷新未确认组句。
7. 第二个来源完成后，helper 去重合并并发布 revision 2；若内容没有变化则不重复刷新。
8. cloud filter 在其他排序 filter 和 `uniquifier` 之前先缓存一个有界的本地候选窗口，按本地原始顺序保留 `insert_after` 个候选，再插入云候选；同文时只保留非云版本。
9. 首轮双源均结束且过滤重复项造成云候选缺口时，Lua 只补查一次：使用新请求编号、较短防抖和更大的候选池；最终显示仍由 `max_candidates` 截断。
10. 用户选择云候选后，Lua 通过实际上屏文本确认选择，并显式写入当前方案用户词库；被抑制的本地/大模型候选不走云词显式学习路径。

旧 HTTP 任务不直接修改候选菜单。任何响应只有通过“请求编号仍相同”和“当前 Rime context 仍匹配”两层检查后才可见。
候选确认不会稳定触发 `update_notifier`，所以 Lua 还会在 `select_notifier` 中重新调度；即使完整输入不变，只要当前 segment 推进，就会为剩余拼音创建新请求。
cloud filter 在候选菜单重建过程中运行，此时 `Context.has_menu()` 会暂时为假；filter 因而只校验请求编号、完整输入和当前 segment，不把菜单的瞬时状态误判为过期响应。processor 真正激活响应时仍要求菜单存在。

## 配置语义

| 配置项 | 责任组件 | 语义 |
|---|---|---|
| `delay_ms` | helper | 输入停止多久后开始 HTTP |
| `timeout_ms` | helper | 每个 provider 的请求上限 |
| `candidates_per_source` | helper | 每个 provider 最多解析多少候选 |
| `max_candidates` | helper | 双源按文本去重后的总上限 |
| `insert_after` | Lua filter | 先输出多少个本地候选 |
| `min_input_length` | Lua processor | 触发云查询的最短输入长度 |
| `learn_to_user_dict` | Lua processor | 上屏后是否写入用户词库 |
| `refill_on_duplicate` | Lua filter | 过滤本地/大模型重复项后是否发起一次补查 |
| `refill_delay_ms` | helper | 补查防抖时间 |
| `refill_candidates_per_source` | helper | 补查时每个 provider 的候选池上限 |
| `refill_max_candidates` | helper | 补查时双源合并池上限，不是最终显示数量 |

## 平台责任

每个平台目录必须提供：

- 可执行 helper 的源码和可复现构建方式；
- 启动、单例、健康检查与退出策略；
- 不把网络 I/O 放进 Rime 主线程的保证；
- helper 完成新 revision 后唤醒当前 Rime context 的方式；
- 安装、配置、日志和故障排查说明；
- 对“输入期间无卡顿”和“过期响应不显示”的实测证据。

provider URL、请求解析和合并规则在不同语言实现中应保持行为一致，但不要求源码结构完全相同。

## 重复过滤与补查

cloud translator 使用高权重，cloud filter 因而必须位于 `long_word_filter` 等改序 filter 和 `uniquifier` 之前。否则云候选会先改变长词过滤器的基准，例如输入 `xian` 时把“西安、锡安”错误地提到原始本地首选“先、线”之前。

filter 最多预读 50 个本地候选：先按原顺序输出 `insert_after` 个本地候选，再插入云候选，最后继续本地候选。同文云候选在这个窗口内会被标记为 suppressed，不参与显式云词学习；已有的 mixed genuine candidate 仍优先采用用户词版本，其次采用第一个非云版本。

补查不是无限重试：只允许从普通首轮请求进入一次带 `-refill-` 标记的新请求。默认把每源解析量从 5 扩大到 10、双源合并池扩大到 20，然后由 filter 删除本地/大模型重复项并只输出 `max_candidates` 个云候选。若扩大后仍不足，不再联网。

首轮某一 provider 仍为 `pending` 时不补查，避免第二来源本可自然补足却产生额外网络请求。一次完整输入最多产生两轮、每轮两个并发 HTTP 请求。

## Windows 当前生命周期

Windows helper 在方案初始化时按需启动，通过 session-local mutex 保证单实例。它每 20 ms 检查请求文件、每 2 秒写一次心跳，目前没有空闲自动退出：小狼毫退出后 helper 仍可能驻留，直到注销、重启、手动结束或发生主循环级致命异常。

Lua 将 6 秒内更新过的心跳视为存活；心跳过期后，在下一次方案初始化或请求写入时尝试重新拉起，并有 5 秒重复启动节流。该行为将在后续版本评估为“按需启动 + 空闲退出 + 文件变更通知”，但改变前应先补充回归测试。

## macOS 共享 helper 生命周期

Swift helper 由 Lua 在方案初始化或写请求时按需启动，通过 Rime 用户目录中的 `flock` 锁保证单实例。它每 20 ms 检查请求文件、每 2 秒写一次心跳；Lua 同样采用 6 秒存活窗口和 5 秒重复启动节流。helper 当前没有空闲退出，前端重启后原 helper 可以继续复用。

每次成功写入新 revision 后，helper 都会发布目录限定的鼠须管刷新通知。Fcitx5 不监听该通知，仍使用自己的进程内 addon，因此两个前端可以共享 helper 源码而不共享 Rime 运行目录或 session。

## Fcitx5-Mac 刷新生命周期

刷新 addon 运行在 Fcitx5 进程内，每 25 ms 比较响应文件快照。只有当前输入上下文有焦点且正在使用 `rime` 时，它才向该引擎直接投递私有 `F24`；没有焦点、已经切换方案或响应为空时安全忽略。addon 不执行网络请求，也不把按键发送给前台 macOS 应用。

## 鼠须管刷新生命周期

鼠须管应用代理使用 `deliverImmediately` 监听 `SquirrelCloudPinyinResponseReadyNotification`，并用标准化后的 Rime 用户目录作为通知对象过滤条件。回调切换到主线程后，只处理当前 panel 的 input controller。

input controller 必须同时满足 client 存在、session 非零且 librime 仍能找到该 session，才把私有 `F24` 直接交给当前引擎并更新候选界面。Lua processor 随后继续验证请求编号、当前输入、菜单状态和选择位置；任一条件不匹配即吞掉刷新而不改变候选。

## 用户词学习边界

helper 只返回候选文本、拼音和来源，不打开任何 Rime 数据库。Lua 在 commit notifier 中匹配实际上屏文本，然后调用当前 schema 的 `Memory:update_userdict`。

因此：

- Space、数字键和鼠标选择走同一确认路径；
- 未上屏或已经过期的云候选不会写库；
- 关闭 `learn_to_user_dict` 后只关闭扩展的显式写入，不改变方案自身学习行为。

## 失败降级

- 单源失败：使用另一来源。
- 双源失败：不产生云候选，本地菜单保持原样。
- helper 不存在或崩溃：本地输入继续工作，Lua 在后续请求检查心跳并尝试拉起。
- 用户已继续输入：旧响应丢弃，不尝试强制恢复。
- 前台窗口变化或候选选择已移动：响应可写入状态文件，但不注入刷新事件或不刷新当前组句。
