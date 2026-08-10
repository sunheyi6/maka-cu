## [2026-08-10 14:41] | Task: Confirm a press through window topology

### 🤖 Execution Context
* **Agent ID**: `Codex`
* **Base Model**: `GPT-5`
* **Runtime**: `Codex Desktop`

### 📥 User Query
> Continue adopting proven Computer Use behavior and complete the real modal and multi-window gate.

### 🛠 Changes Overview
**Scope:** `maka.cu/2` element dispatch outcome classification and live CUA Lab evidence.

**Key Actions:**
- **Window-topology recovery**: recover an otherwise unknown single press only when the target PID's window ID set changes twice within five seconds.
- **Fail-closed boundary**: exclude multi-click, value, text, scroll and window management actions from the recovery.
- **Foreground restoration**: request the exact previous app only when the target activates itself; independent live evidence verifies the target remains background.
- **Live matrix**: verify modal open/close and secondary open/button/scroll/close for five consecutive runs with an independent oracle.

### 🧠 Design Intent (Why)
*AppKit may create or destroy a window while `AXPress` is returning `cannotComplete`. Reporting that as unknown tells the model to inspect or retry an action whose requested outcome is already visible. A stable same-app window-topology change is narrow external evidence that the press completed; every case without that evidence remains unknown.*

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/HostDispatchPolicy.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/HostProtocolServer+Observe.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/HostDispatchTests.swift`
- `docs/HOST_PROTOCOL.md`
- `docs/ARCHITECTURE.md`
- `docs/QUALITY_SCORE.md`
