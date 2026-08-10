# macOS 共享组件

这里保存 Fcitx5-Mac 与鼠须管共同使用的进程外网络 helper 和 Lua 候选逻辑。两个前端只分别实现“响应到达后如何安全刷新当前 Rime 上下文”。

## 文件

- `helper/CloudPinyinAsyncHelper.swift`：监听请求文件、并发查询搜狗和 Google、按 revision 原子写入响应。
- `lua/cloud_pinyin_async.lua`：生成请求、拒绝过期响应、合并候选、处理同文去重/补查并将选中的云候选写入当前用户词典。

helper 每次成功写入响应后都会发布 `SquirrelCloudPinyinResponseReadyNotification`，通知对象是标准化后的 Rime 用户目录路径：

- 鼠须管通过该通知立即刷新当前 session；
- Fcitx5-Mac 不依赖通知，而由进程内 addon 观察响应文件；
- 两条通道都只把私有 F24 投递给输入法引擎，不发送全局键盘事件。

文件协议见 [`../../../docs/file-protocol-v1.md`](../../../docs/file-protocol-v1.md)。前端实现分别见 [`../fcitx5`](../fcitx5/README.md) 与 [`../squirrel`](../squirrel/README.md)。
