## [2026-08-10 13:14] | Task: 锁定 modal 与多窗口路由

### 🤖 Execution Context
* **Agent ID**: `Codex`
* **Base Model**: `GPT-5`
* **Runtime**: `Codex desktop`

### 📥 User Query
> 继续参考 Codex Computer Use 的 modal、sheet 和 multi-window 能力。

### 🛠 Changes Overview
**Scope:** host protocol window resolution 与 deterministic tests

**Key Actions:**
- **App Target**: 证明 `{kind:"app"}` 选择 front-to-back inventory 中的 sheet。
- **Exact Window**: 证明 `{kind:"window"}` 严格选择指定 secondary window。
- **Sheet Ownership**: 抽出 frame matcher，锁定 direct AXWindow 优先、随后匹配 `AXSheet` / `AXDrawer` child。

### 🧠 Design Intent (Why)
*AppKit sheet 在 CGWindow 与 AX 中属于不同层级；必须把这种 ownership 差异写成机械合同，不能依赖标题或主窗口 fallback。*

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/HostAccessibilityAdapter.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/HostObserveContractTests.swift`
- `docs/HOST_PROTOCOL.md`
