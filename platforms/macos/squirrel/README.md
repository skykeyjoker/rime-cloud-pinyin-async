# macOS / 鼠须管实现

这套实现复用 [`../common`](../common/README.md) 的 Swift helper 与 Lua 候选逻辑，只对鼠须管增加一个很小的前端刷新补丁。网络请求始终在独立 helper 进程中执行，不阻塞 librime/Lua，也不需要 macOS“辅助功能”权限。

## 刷新通道

1. Lua 把带请求编号的当前全拼写入 Rime 用户目录。
2. Swift helper 并发查询搜狗与 Google；每次原子写入新 revision 后，发布 `SquirrelCloudPinyinResponseReadyNotification`，通知对象为标准化后的 Rime 用户目录路径。
3. 鼠须管仅监听与自身用户目录完全一致的通知，并切回主线程。
4. 当前输入控制器确认 client、session 与 librime session 均有效后，把私有 F24 直接交给当前 Rime 引擎。
5. Lua 再次核对请求编号、输入内容、组句菜单与候选选择位置，过期结果直接丢弃。

这里没有生成系统级键盘事件，因此刷新键不会泄漏到前台应用；切换应用、提交输入或移动候选选择后到达的旧响应也不会污染当前菜单。

## 兼容基线

当前补丁已在以下组合完成构建和真实输入验证：

- Apple Silicon；
- `rime/squirrel@1dde02217f11`；
- librime 1.17.0，包含 Lua、octagram 与 predict 插件；
- 白霜拼音、万象 LTS 与本仓库的异步双源云候选。

鼠须管上游修改相关 Swift 文件后，必须重新执行补丁兼容检查和端到端验证，不能直接沿用旧二进制。

## 准备源码并应用补丁

```bash
git clone --recurse-submodules https://github.com/rime/squirrel.git ../squirrel
git -C ../squirrel checkout 1dde02217f11
git -C ../squirrel submodule update --init --recursive
./platforms/macos/squirrel/apply-squirrel-patch.sh ../squirrel
```

脚本只在 `git apply --check` 成功时修改两个 Swift 文件；补丁已存在时会直接退出，上游不兼容时不会尝试模糊套用。

## 构建

只构建本机架构的 helper：

```bash
./platforms/macos/squirrel/build.sh
```

同时构建已经打补丁的鼠须管：

```bash
SQUIRREL_SOURCE=../squirrel \
CODE_SIGN_IDENTITY="Apple Development: your identity" \
./platforms/macos/squirrel/build.sh
```

可选环境变量：

- `ARCHS`：当前单一目标架构，默认 `uname -m`；
- `SQUIRREL_DERIVED_DATA`：Xcode 构建目录，默认放在 `~/Library/Developer/Xcode/DerivedData/RimeCloudSquirrel`；
- `CODE_SIGN_IDENTITY`：同时签名 helper 和鼠须管应用。此次验证使用 Apple Development 身份；未验证无证书的长期使用行为。

脚本会验证 helper 签名、鼠须管完整签名，以及最终可执行文件是否包含刷新通知。官方鼠须管的 `make release` 会准备 librime 与数据依赖，首次构建时间较长。

## 安装

先完整备份现有鼠须管应用和 `~/Library/Rime`，并确保系统中只保留一个 `im.rime.inputmethod.Squirrel`。不要同时放置系统级与用户级的同 bundle ID 副本。

1. 将共享组件放入鼠须管用户目录：

   ```bash
   mkdir -p ~/Library/Rime/lua
   install -m 0644 platforms/macos/common/lua/cloud_pinyin_async.lua ~/Library/Rime/lua/
   install -m 0755 platforms/macos/squirrel/dist/cloud_pinyin_async_helper ~/Library/Rime/
   ```

2. 将 `examples/rime_frost.custom.yaml` 中的补丁合并进自己的 `rime_frost.custom.yaml`，不要覆盖其他自定义配置；cloud filter 必须保持在 `engine/filters` 最前面，避免后续长词过滤器改变原始本地前排。

3. 用构建产物替换现有鼠须管。用户级安装位置为 `~/Library/Input Methods/Squirrel.app`；若现有版本位于 `/Library/Input Methods`，应在备份后替换原位置，而不是再安装第二份。

4. 关闭官方自动更新，避免本地前端补丁被覆盖：

   ```bash
   defaults write im.rime.inputmethod.Squirrel SUEnableAutomaticChecks -bool false
   ```

5. 重新部署鼠须管。首次安装若无法选择，在“系统设置 → 键盘 → 文字输入 → 编辑”中手动添加“鼠须管”；macOS 也可能要求注销并重新登录。

运行时文件位于 `~/Library/Rime`：

- `cloud_pinyin_async.request`
- `cloud_pinyin_async.response`
- `cloud_pinyin_async.heartbeat`
- `cloud_pinyin_async.lock`
- `cloud_pinyin_async.log`

日志只记录请求编号、拼音长度、来源状态和耗时，不记录完整输入或候选正文。

## 验收结果

本实现已完成真实键盘验证：

- 本地候选保持即时响应，网络请求无可感知卡顿；
- 停止输入后按配置防抖查询；
- 搜狗与 Google 先到先显示、后到合并；
- 云候选显示 `☁搜`、`☁谷` 或 `☁搜谷`；
- `xian` 等单音节输入保留白霜原始本地首选；
- 过期响应不会进入新的候选菜单；
- 本地、用户词和万象同文候选优先，并且最多补查一轮；
- 云候选上屏后写入当前方案用户词典；
- helper 断网或单源超时不影响本地输入。

## 回退

恢复备份的官方鼠须管应用，移除 schema 中的三个 `cloud_pinyin_async` 组件并重新部署即可停用。运行时状态文件可以保留；它们不会影响未加载该 Lua 组件的方案。
