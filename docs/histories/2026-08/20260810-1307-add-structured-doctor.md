## [2026-08-10 13:07] | Task: 增加结构化 doctor

### 🤖 Execution Context
* **Agent ID**: `Codex`
* **Base Model**: `GPT-5`
* **Runtime**: `Codex desktop`

### 📥 User Query
> 参考 Kimi CU 的诊断与交付体验，继续吸收三方实现优点。

### 🛠 Changes Overview
**Scope:** CLI diagnostics、native capability / signature introspection、文档

**Key Actions:**
- **Doctor JSON**: 新增 `doctor --json`，稳定输出协议、版本、权限、锁屏、native capability、签名与 readiness。
- **Side-effect Control**: JSON mode 永不拉起 UI；text mode 支持 `--no-onboarding`。
- **Fail-closed Readiness**: metadata、screenshot 与 trusted WebContent click 分别按所需权限/锁屏/SPI 判断。
- **MCP Decision Record**: 记录当前 mcp-use scaffold/version/stdio/security 阻塞，不把不稳定 HTTP adapter 混进主线。

### 🧠 Design Intent (Why)
*把 Kimi 的可安装/可诊断体验拆成可独立落地的部分：先让 operator 和 host 能机械读取真实运行边界，再处理签名服务与标准 MCP adapter。*

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/DoctorDiagnostics.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/OpenComputerUseCLI.swift`
- `apps/OpenComputerUse/Sources/OpenComputerUse/OpenComputerUseMain.swift`
- `docs/exec-plans/tech-debt-tracker.md`
