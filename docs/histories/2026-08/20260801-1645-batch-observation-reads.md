## [2026-08-01 16:45] | Task: 让 observe 少跨进程

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5`
* **Runtime**: macOS 26.5.2 (25F84), Swift 6.2, arm64e

### 📥 User Query
> 真机轨迹里 observe 带截图必然超时（5.8–8.0 s，5/5 全失败），不带截图也要 0.76–7.4 s。
> 要求先测量再动手，每条优化都要有改前改后的实测中位数，不接受用降低正确性换速度。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`（Accessibility 适配层、截图层）

**Key Actions:**
- **批量读属性**: `HostAXNode` 改为一次 `AXUIElementCopyMultipleAttributeValues`
  取回整份属性，并在节点内缓存。此前 walk 会向同一个元素分别问四次 `AXRole`
  ——wire 一次、digest 一次、子节点的祖先链一次、`children` 内部一次。
- **祖先链记忆**: 新增 `HostAXAncestryMemo`，按元素记住「自身角色 + 祖先链」，
  子节点直接命中父节点那一条，miss 时顺手把父节点填进去。
- **截图内容缓存**: 新增 `HostShareableContentCache`，`SCShareableContent.current`
  不再每张截图重取一次；每次复用前都拿 `CGWindowListCopyWindowInfo` 校验目标窗口
  的 frame 没有变。
- **遍历属性单一来源**: 新增 `hostChildTraversalAttributeNames`，
  `childTraversalAttributes` 能说出的名字只有这一份。
- **可复跑基准与差分**: 新增观测基准、批量读差分、属性列表漂移守卫。

### 🧠 Design Intent (Why)
每次 Accessibility 属性读取都是一次跨进程往返，本机实测 34–48 µs，System Settings
这类由别的进程托管视图的窗口更贵。改之前每个元素要花 32.4–43.8 次往返，其中真正
落到 wire 上的只有 12 个属性；4.5–15.7 次是祖先链、5 次是子列表、其余约 10 次是
同一个属性被不同调用方各读一遍。

正确性不是靠信任换来的：批量读会不会改变观测，是拿一个逐属性读的旧节点跑同一棵树
做逐字段比对得出的，包含 §4.3 digest——digest 一动，对应元素的每次 dispatch 都会
被 `element_digest_mismatch` 拒掉。差分第一次跑就抓到批量读把 `AXContents` 填进了
`AXChildren` 的槽位：访达的列表返回列而不是行，156 个元素变成 240 个，确定性复现，
不报任何错。

截图内容缓存按 frame 校验而不是按时间过期，是因为过期时间内的陈旧 `SCWindow` 会带
着陈旧 `frame`，而 `HostCapture` 的输出缓冲正是按它定尺寸——那就是 §5.3 记下的那个
缺陷。校验一个窗口 id 只要一次窗口服务器调用，能把这条失败从「不太可能」变成
「不可达」。

### 📊 Measured (中位数，同一台机器，负载 4–7)
| 窗口 | walk 逐属性 | walk 批量 | AX 往返 逐属性 | AX 往返 批量 |
|---|---|---|---|---|
| 计算器 65 元素 | 94.3 ms | 37.7 ms | 2254 | 132 |
| 文本编辑 14 元素 | 46.2 ms | 14.3 ms | 398 | 30 |
| 访达 156 元素 | 703.7 ms | 130.4 ms | 5465 | 314 |
| 系统设置 185 元素 | 1879.7 ms | 630.0 ms | 6979 | 372 |
| HAPI 1500 元素 | 2423.4 ms | 775.0 ms | 62926 | 3020 |

窗口截图：155.5 ms → 77.8 ms（四个窗口一致，2.0x）。

整条 `observe`（走协议，含截图）：计算器 305.1 → 165.6 ms，文本编辑 222.7 → 127.6 ms，
访达 963.8 → 259.4 ms，系统设置 2078.7 → 749.8 ms，HAPI 1500 元素 1003.4 ms。

量过没收益：8 条并发读同一批元素只有 0.97–1.61x（中位 1.15x），Accessibility 在被观测
应用的主运行循环上串行，付出确定性和顺序不值得。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/HostAccessibilityAdapter.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/HostImageStore.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/HostObservePerformanceLiveTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/HostObserveBatchedReadLiveTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/HostAXBatchedAttributeDiagnosticTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/HostAXAttributeListTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/LegacyHostAXNode.swift`
