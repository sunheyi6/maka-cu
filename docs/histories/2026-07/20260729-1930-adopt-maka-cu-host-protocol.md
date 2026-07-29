## [2026-07-29 19:30] | Task: 用 maka.cu/1 host protocol 取代 MCP tool 层

### 🤖 Execution Context
* **Agent ID**: `/root`
* **Base Model**: `Claude Opus 5`
* **Runtime**: `Claude Code / macOS arm64`

### 📥 User Query
> 按 `docs/maka-cu-host-protocol.md`（Maka 仓库，commit 36e18324）实现 Swift 侧：删掉面向模型的 tool 层，加上 host protocol server，给 snapshot 一个 id、给 element 一个稳定 token，并在 dispatch 时强制帧绑定。

### 🛠 Changes Overview
**Scope:** macOS executor 协议面、帧绑定、CLI 入口、测试与文档。

**Key Actions:**
- **删掉模型面**: `MCPServer.swift`、`ToolDefinitions.swift`、`ComputerUseToolDispatcher.swift`、`ToolResult.swift`、`MacOSAppAgentProxy.swift`、`MCPAppRuntime.swift`、`OpenComputerUseSmokeSuite`，以及 `mcp` / `call` 两个 CLI 命令。
- **加上 host protocol**: 新增 `HostProtocol/`，实现 line-framed JSON-RPC、握手（含全部 limits 与 capabilities）、session 生命周期、`observe`、三个 `dispatch.*`、`window.list` / `apps.list` / `apps.launch` / `permissions.check` / `screen.capture`、`$/cancel`、lane 调度、hostPid watchdog 与 SIGTERM 收尾。
- **帧绑定**: snapshot 带 128-bit per-process nonce 的 id 与五态生命周期（live / spent / superseded / expired / evicted）；element token 只在自己那张 snapshot 的字典里按整串匹配；dispatch 前跑 E1（引用还活着）/ E2（pid start time 未变）/ E3（digest 未变）三项检查，digest 覆盖未截断的 value。
- **路径声明化**: `tier` / `path` 配对是固定表，`allowGlobalPointer=false` 时够不到目标就 `dispatch_refused` + `wouldRequirePath`，不再 fallback；`effect` 与 `verification` 分开，`action_result` 不再冒充确认。
- **图片按引用**: 截图写进握手声明的 `imageDir`，生命周期跟着 snapshot 走，响应里没有 base64。

### 🧠 Design Intent (Why)
*上游 `cua-driver` 把 element **索引** 在动作发生时重新解析到一棵新树上，"点击 7 号元素"实际含义是"点击此刻恰好排在第 7 的东西"。Maka 之前在 TypeScript 侧靠重新抓一遍窗口再按 role/label/value/frame 匹配来补救，每个动作多走一趟 AX 树，还看不见 driver 没打印的东西。这次把绑定放回 executor：token 只在自己的 snapshot 里有意义，quoted snapshot 的状态由 executor 判定，五种失效各有各的 code，因为它们对 host 意味着不同的下一步。*

*同时删掉 executor 里的模型面。tool schema、instructions、渲染文本都是模型读的字，Maka runtime 已经拥有它们；executor 再放一份就是第二份会漂移的副本，也是绕过自家 bridge 的一座桥。*

*`ComputerUseService` 的点击启发式（Electron web row、descendant 扫描、hit-test 兜底）没有被搬进 host protocol：它们的做法是点一个不是调用方指名的元素，这正是帧绑定要杜绝的。新的 observe 不做节点省略，父层容器本身就带着 `press` 出现在树里，模型可以直接指名它——能力从"猜"挪到了"看得见"。*

### ✅ Verification
- `swift build -c release`：通过。
- `swift test`：176 tests，1 failure；唯一失败是 fork 里缺失 `docs/references/codex-computer-use-reverse-engineering/assets/` 参考图导致的 `testSoftwareCursorGlyphLoadsCursorMotionReferenceImage`，在本次改动之前的 HEAD 上同样失败。
- `swift test --filter HostProtocolTests`：49 tests，0 failures。
- 真机冒烟：`OpenComputerUse host` 走完 `host.hello` → `session.begin` → `capture.start`（`not_implemented`）→ `window.list` → `apps.list` → `session.end`，window.list 的 `zIndex` 严格递减。这轮冒烟抓到一个自己写的死锁：`session.end` 在 session lane 上调 `SoftwareCursorOverlay.reset()`，`DispatchQueue.main.sync` 撞上停在 `readLine` 的主线程，整个请求不回。host protocol 本来就不画 cursor（Maka 画自己的），改成不碰 overlay。
- `./scripts/check-docs.sh`：通过。
- 未做真机验证：`observe` / `dispatch.*` 对真实 AX 树、ScreenCaptureKit 与遮挡判定的行为还没有在真桌面上跑过。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/InputSimulation.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/OpenComputerUseCLI.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/OpenComputerUseVersion.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/HostProtocolTests.swift`
- `apps/OpenComputerUse/Sources/OpenComputerUse/OpenComputerUseMain.swift`
- `Package.swift`
- `Makefile`
- `docs/ARCHITECTURE.md`
