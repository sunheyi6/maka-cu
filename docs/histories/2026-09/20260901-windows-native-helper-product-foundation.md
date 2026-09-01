## [2026-09-01 09:00] | Task: Migrate the Windows native helper

### 🤖 Execution Context
* **Agent ID**: `windows_native_product`
* **Base Model**: `gpt-5.6-luna (high)`
* **Runtime**: `Codex desktop`

### 📥 User Query
> 将 Windows Computer Use 的 C#/.NET helper 从实验仓库迁入 maka-cu，补齐可复现构建、fixture、生命周期验证和产品安全边界。

### 🛠 Changes Overview
**Scope:** `apps/OpenComputerUseWindows` and repository Windows documentation.

**Key Actions:**
- **Native executor**: Migrated the supervised C#/.NET UIA and Windows Graphics Capture helper into `apps/OpenComputerUseWindows/native/` while preserving the existing Go CLI/MCP compatibility surface.
- **Identity and safety**: Enforced explicit target identity for capture, post-capture revalidation, opaque one-use snapshots, runtime-id/native-child validation, typed outcomes, and disabled debug timing endpoints by default.
- **Fixture and lifecycle**: Added the Windows Forms fixture, deterministic self-contained `win-x64` publish script with SHA-256 manifest, protocol regressions, parent-death checks, and same-window control replacement coverage.
- **Repository integration**: Added Make targets, architecture/reliability/quality documentation, active plan updates, and this history record.

### 🧠 Design Intent (Why)
The native helper needs a process boundary that can be supervised and restarted when a UI Automation provider blocks. Keeping it separate from the Go compatibility runtime avoids duplicating tool ownership while allowing the future Maka host to select the native executor directly. Target-window capture and semantic actions fail closed when HWND, process incarnation, or window/control identity changes.

### 📁 Files Modified
- `apps/OpenComputerUseWindows/native/MakaCuWindows.csproj`
- `apps/OpenComputerUseWindows/native/Program.cs`
- `apps/OpenComputerUseWindows/native/WgcCapture.cs`
- `apps/OpenComputerUseWindows/native/README.md`
- `apps/OpenComputerUseWindows/fixture/HangWindowFixture/HangWindowFixture.csproj`
- `apps/OpenComputerUseWindows/fixture/HangWindowFixture/Program.cs`
- `scripts/windows/publish-native.ps1`
- `scripts/windows/lifecycle-driver.mjs`
- `scripts/windows/protocol-regression.mjs`
- `scripts/windows/parent-probe.mjs`
- `scripts/windows/capture-probe.mjs`
- `docs/ARCHITECTURE.md`
- `docs/QUALITY_SCORE.md`
- `docs/RELIABILITY.md`
- `docs/exec-plans/active/20260422-windows-computer-use-runtime.md`
