# Windows native executor

This directory contains the supervised C#/.NET executor used by the Windows
Computer Use backend. It speaks the private line-delimited JSON-RPC protocol
`maka.cu.windows/0` over stdin/stdout. The Go program in the parent directory
remains the compatibility CLI/MCP implementation; this executor is kept as a
separate process so a blocked UI Automation provider can be terminated and
restarted without taking down the host.

The executor has five supported methods: `initialize`, `list_windows`,
`observe`, `act`, and `capture`. `observe` requires an explicit HWND and
returns a one-use snapshot id plus opaque element tokens. `act` spends the
snapshot before dispatch, revalidates PID, process start time, HWND and window
generation, and returns a typed `verified`, `refused`, or `unknown` outcome.
`capture` accepts the HWND and all identity fields from an observation and uses
Windows Graphics Capture `CreateForWindow`; it never falls back to a screen
rectangle. UIA calls run on a dedicated MTA lane and the stdout writer is
bounded so a dead host cannot leave an unbounded helper behind.

The `debug_sleep` method and `debugPostDispatchDelayMs` request field are
disabled in normal processes. Fixture tests opt in with
`MAKA_CU_WINDOWS_ENABLE_DEBUG_ENDPOINTS=1`; this variable is not part of the
product configuration.

Build a framework dependent debug binary with:

```powershell
dotnet build apps/OpenComputerUseWindows/native/MakaCuWindows.csproj -c Release
```

Build the reproducible self-contained `win-x64` artifact with:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/windows/publish-native.ps1
```

The publish script writes a manifest containing the SDK, publish settings and
SHA-256 hashes. It deliberately marks the artifact `distributionReady: false`
until supported Windows release testing, signing and installer ownership are
defined.

For an interactive fixture run, build the fixture and run:

```powershell
dotnet build apps/OpenComputerUseWindows/fixture/HangWindowFixture/HangWindowFixture.csproj -c Release
node scripts/windows/lifecycle-driver.mjs `
  apps/OpenComputerUseWindows/native/bin/Release/net8.0-windows10.0.22621.0/maka-cu-windows.exe `
  apps/OpenComputerUseWindows/fixture/HangWindowFixture/bin/Release/net8.0-windows10.0.22621.0/maka-cu-windows-fixture.exe
```

The lifecycle driver owns only its named fixture and helper processes. It
covers target-window WGC capture under occlusion, cancellation settlement,
blocked-provider recovery, parent-death cleanup, whole-window recreation and
same-window control replacement. These checks need an interactive desktop;
they are not clean-machine or supported-release certification.
