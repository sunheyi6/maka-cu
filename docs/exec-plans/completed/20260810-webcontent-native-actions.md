# WebContent 原生动作与 Web 控件闭环

## 目标

让 `maka.cu/2` 在不放宽 snapshot/token/digest 安全合同的前提下，优先操作真实
WebContent AX 元素，并补齐严格 retained-element refetch、数值 slider 与元素 scroll
的可验证执行路径。

## 范围

- 包含：
  - 读取 AX 元素真实 owner PID，并绑定对应进程启动时间。
  - 当宿主镜像元素与唯一 WebContent 元素重合时，内部提升到真实 WebContent 元素。
  - retained AX 引用失效时，仅接受同一进程世代内、identity-preserving 的唯一 fresh refetch。
  - 按 AXValue 实际类型写入 slider 等数值控件并做等价 readback。
  - AX page action 不可用时，对已绑定元素执行 PID 定向 scroll。
  - CUA Lab 的 OOP trusted event、slider、scroll 和 stale/refetch 回归。
- 不包含：
  - 开放 Maka host 当前禁用的通用 coordinate/key compatibility surface。
  - 广播事件到多个 WebContent 进程。
  - CDP、DOM 注入或 JavaScript `.click()`。
  - 签名、notarization 和 release pin 更新。

## 背景

- 相关文档：
  - `docs/HOST_PROTOCOL.md`
  - `docs/ARCHITECTURE.md`
- 相关代码路径：
  - `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/`
  - `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/`
- 已知约束：
  - mutation snapshot 仍为 single-use。
  - OOP 目标必须唯一并绑定进程启动时间；不能按进程名或候选顺序猜测。
  - `AXUIElementPerformAction` 成功不等于业务成功，仍需现有 postcondition 规则。

## 风险

- 风险：宿主镜像元素或 released token 被错误映射到无关元素。
- 缓解方式：要求 role、稳定名称或 identifier、frame 和动作能力共同匹配，且候选唯一。
- 风险：WebContent 重启后 PID 被复用。
- 缓解方式：同时校验 actual PID 与进程启动时间。
- 风险：scroll fallback 偷换成全局输入。
- 缓解方式：只允许 `cg_event_pid`，保持 global pointer gate 关闭。

## 里程碑

1. 建立 actual PID、唯一 refetch 和 WebContent promotion 的纯逻辑与测试。
2. 接入 element dispatch，并补齐 slider/scroll。
3. 跑 Swift 全量测试和真实 CUA Lab probe。
4. 更新架构、协议说明、质量评分和 history。

## 验证方式

- 命令：
  - `swift test --filter HostDispatchTests`
  - `swift test --filter HostProtocolTests`
  - `swift test`
- 手工检查：
  - CUA Lab OOP 按钮产生 `MouseEvent.isTrusted=true`。
  - slider 请求 `42` 后 oracle 为 `42`。
  - scroll region offset 增加。
- 观测检查：
  - 前台 PID 不变。
  - stale/ambiguous target 无错误副作用。
  - dispatch 结果的 tier/path/effect/verification 配对合法。

## 进度记录

- [x] 确认 AX 元素的 `_AXUIElementGetActualPid` 可返回独立 WebContent PID。
- [x] 确认真实 WebContent AXButton 的 `AXPress` 产生 trusted DOM event。
- [x] 完成 actual PID 绑定、唯一 refetch 与 WebContent promotion。
- [x] 完成 slider 与 scroll。
- [x] 完成全量与真机验证并归档。

## 决策记录

- 2026-08-10：不把 WebContent PID放到模型可见协议；它是 executor 的 dispatch
  证据，不是模型选择目标所需的应用文本。
- 2026-08-10：coordinate OOP 事件若不能同时证明 WebContent PID 和 host window
  绑定，就继续 fail closed；不以普通 `postToPid` 换 PID冒充完成。
- 2026-08-10：WebContent 最终事件使用 host window owner 的单通道
  `SLEventPostToPid`；WebContent PID/start time 仍是元素身份与 renderer restart
  检查，WindowServer 负责最后的 renderer hop。
