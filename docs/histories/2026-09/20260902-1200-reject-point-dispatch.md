## [2026-09-02 12:00] | Task: Reject host point dispatch

### Execution Context

- Agent: Codex
- Runtime: Codex desktop

### User Query

> Make the Maka Computer Use execution boundary semantic-only while retaining a typed compatibility response for older hosts.

### Changes

- `host.hello` now advertises an empty `pointActions` capability.
- `dispatch.point` remains parseable but always returns `unsupported_action`.
- The refusal does not resolve or consume a snapshot, inspect a window, select a path, post an event, or run post-action observation.
- Removed the unused host-protocol point path selector and obsolete point-success tests.
- Updated the protocol and architecture documents to distinguish the semantic Maka host boundary from the repository's legacy MCP/CLI coordinate APIs.

### Design Intent

Maka exposes one model action space across platforms. Native executors implement revision-bound AX/UIA semantic actions and verified keyboard targeting; they do not add platform-specific coordinate actions or silently fall back from semantic intent to pixels.

### Verification

- `swift test --filter HostDispatchTests`
- `swift test`

### Files Modified

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/HostProtocolServer+Observe.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/HostProtocolWire.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/HostDispatchPolicy.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/HostDispatchTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/HostProtocolTests.swift`
- `docs/HOST_PROTOCOL.md`
- `docs/ARCHITECTURE.md`
