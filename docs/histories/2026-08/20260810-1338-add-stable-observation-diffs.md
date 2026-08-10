## [2026-08-10 13:38] | Task: Add stable observation differences

### 🤖 Execution Context
* **Agent ID**: `Codex`
* **Base Model**: `GPT-5`
* **Runtime**: `Codex Desktop`

### 📥 User Query
> Continue improving Maka CU with the strongest proven Computer Use mechanisms, including Codex-style AX revision handling.

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit` host protocol, snapshot registry, tests, and protocol documentation.

**Key Actions:**
- **Stable revision identity**: assign DFS stable ids on the first observation, preserve them across structurally matched sibling revisions, and allocate new ids above the previous maximum.
- **Bounded AX difference**: emit no-change, ordered remove/insert/update changes, compressed removed-id ranges, or a full-tree fallback when the difference is not smaller.
- **Lifecycle integration**: retain spent snapshots as difference baselines without restoring their dispatch authority.
- **Wire contract**: add `element.stableId` and optional `snapshot.difference` while keeping the full current element tree authoritative.
- **Verification**: add revision, ordering, range, budget, spent-baseline, flat-tree, and protocol no-change tests.

### 🧠 Design Intent (Why)
*A model should not reread an unchanged accessibility tree after every action, but token savings cannot weaken Maka's snapshot/token/digest safety model. Stable ids are therefore presentation identity only: every action still resolves through the fresh snapshot's opaque token. The executor always returns the complete current tree and falls back to full rendering whenever the difference is not smaller.*

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/HostObservationDifference.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/HostObservation.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/HostProtocolServer+Observe.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/HostSnapshotRegistry.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/HostObservationDifferenceTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/HostObserveContractTests.swift`
- `docs/HOST_PROTOCOL.md`
- `docs/ARCHITECTURE.md`
- `docs/QUALITY_SCORE.md`
