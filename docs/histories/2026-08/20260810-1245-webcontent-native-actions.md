## [2026-08-10 12:45] | Task: 补齐 WebContent 原生动作

### 🤖 Execution Context
* **Agent ID**: `Codex`
* **Base Model**: `GPT-5`
* **Runtime**: `Codex desktop`

### 📥 User Query
> 完成 Maka CU 的 Web 能力，吸收 Codex Computer Use 的 WebContent 与 stale 安全经验。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit` host protocol、macOS input、测试与协议文档

**Key Actions:**
- **WebContent identity**: 绑定 actual PID/start time，并用 XNU coalition 处理 WKWebView 冷启动 readiness。
- **Trusted click**: 去掉唯一叶子 mirror，WebContent 左键点击走 host-window single-channel SkyLight 路径。
- **Strict refetch**: released token 只接受同进程世代、唯一 identity-preserving replacement。
- **Web controls**: 数值 slider 使用可回滚步进动作；scroll 增加 page-button semantic path。
- **Evidence**: 增加 binding/path/readback 单测，并用共享 CUA Lab 重复验证 trusted event、slider、scroll 和 stale 安全。

### 🧠 Design Intent (Why)
*保留 snapshot/token/digest 的 fail-closed 骨架，同时让真实 WebContent 操作产生可信 DOM
事件；任何进程替换、候选歧义或未知部分动作都不能退回到镜像 JS click、全局指针或盲重试。*

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/LiveApplicationInventory.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SkyClickSimulation.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/`
- `docs/HOST_PROTOCOL.md`
- `docs/ARCHITECTURE.md`
