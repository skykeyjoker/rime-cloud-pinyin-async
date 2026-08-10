# macOS / Fcitx5-Mac 实现

这套实现使用 [`../common`](../common/README.md) 中的 Swift helper 与 Lua 候选逻辑，并通过 Fcitx5 进程内 addon 安全刷新当前 Rime 输入上下文。网络请求不会在 Rime/Lua 主线程执行，也不需要 macOS“辅助功能”权限。

## 组成

- `../common/helper/CloudPinyinAsyncHelper.swift`：300 ms 防抖后并发请求搜狗和 Google，先到先发布，写入版本化响应文件。
- `../common/lua/cloud_pinyin_async.lua`：校验请求编号、输入内容和菜单状态，插入云候选并学习上屏结果。
- `fcitx-addon/cloudpinyinrefresh.cpp`：每 25 ms 检查响应文件；更新时只向当前已聚焦的 Rime 引擎直接投递私有 F24，事件不会进入 macOS 按键流。

helper 还会发布供鼠须管使用的分布式通知；Fcitx5 不监听该通知，因此不会改变现有行为。

## 构建

需要当前已安装的 Fcitx5.app，以及与它 ABI 对应的 `fcitx5-macos/fcitx5` 源码。可以把官方仓库克隆到本仓库旁边：

```bash
git clone --recurse-submodules https://github.com/fcitx-contrib/fcitx5-macos.git ../fcitx5-macos-source
FCITX5_SOURCE=../fcitx5-macos-source/fcitx5 ./platforms/macos/fcitx5/build.sh
```

脚本默认寻找同级的 `fcitx5-macos-source/fcitx5`，也可以通过 `FCITX5_SOURCE` 和 `FCITX5_APP_CONTENTS` 显式指定路径。

当前脚本构建本机架构。Apple Silicon 和 Intel 应分别在对应机器上构建后再用 `lipo` 合并；不要拿一端的 Fcitx5 动态库交叉链接另一端。

## 安装位置

- `~/.local/share/fcitx5/rime/lua/cloud_pinyin_async.lua`
- `~/.local/share/fcitx5/rime/cloud_pinyin_async_helper`
- `~/Library/fcitx5/lib/fcitx5/libcloudpinyinrefresh.so`
- `~/Library/fcitx5/share/fcitx5/addon/cloudpinyinrefresh.conf`

把 `examples/rime_frost.custom.yaml` 中的补丁合并进现有配置后重新部署并重启 Fcitx5。

示例安装命令（执行前先备份自己的 Rime 配置）：

```bash
mkdir -p ~/.local/share/fcitx5/rime/lua
mkdir -p ~/Library/fcitx5/lib/fcitx5
mkdir -p ~/Library/fcitx5/share/fcitx5/addon
install -m 0644 platforms/macos/common/lua/cloud_pinyin_async.lua ~/.local/share/fcitx5/rime/lua/
install -m 0755 platforms/macos/fcitx5/dist/cloud_pinyin_async_helper ~/.local/share/fcitx5/rime/
install -m 0755 platforms/macos/fcitx5/dist/libcloudpinyinrefresh.so ~/Library/fcitx5/lib/fcitx5/
install -m 0644 platforms/macos/fcitx5/fcitx-addon/cloudpinyinrefresh.conf ~/Library/fcitx5/share/fcitx5/addon/
```

运行时会在 Rime 用户目录生成 request、response、heartbeat、lock、log 和 bridge 文件。日志只记录请求编号、输入长度、耗时与状态，不保存完整查询内容或候选正文。

## 已验证范围

已在 Apple Silicon、Fcitx5-Mac 0.3.4 / fcitx5 5.1.21 环境验证：

- 搜狗与 Google 并发查询，并按 revision 分两次刷新；
- 云候选按配置插入，保留本地/用户词/万象同文候选并补查一次；
- 选择云候选后写入当前方案用户词典；
- addon 只刷新当前有焦点的 Rime 输入上下文；
- Fcitx5 重启后 helper 可继续复用，断网或单源超时不阻塞本地输入。

动态插件与 Fcitx5 ABI 相关，升级 Fcitx5-Mac 后应使用匹配源码重新构建并复测。

如果重启后菜单为空或暂时不能输入，先切换到 ABC，再切回“小企鹅”，让 macOS 重新建立 InputMethodKit 连接；不要通过反复强制结束进程代替正常重启。
