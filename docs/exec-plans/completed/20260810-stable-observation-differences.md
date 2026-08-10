# Stable observation differences

## 目标

在不改变 snapshot/token/digest dispatch 安全合同的前提下，为同一窗口的连续
Accessibility observations 提供稳定模型 ID 与有界差分，让动作后的模型输入不再重复
整棵未变化的树。

## 范围

- 包含：
  - 首轮 DFS stable ID 分配与后续 sibling-scoped 结构匹配。
  - no-change、remove/insert/update、removed range 与 full fallback。
  - spent snapshot 作为差分基线。
  - `maka.cu/2` wire payload、Swift tests 与 host 文档。
- 不包含：
  - 用 stable ID 直接 dispatch。
  - 只传 patch、不传完整当前元素树。
  - menu tree 差分。
  - 真实 modal/multi-window 交互验证。

## 背景

- 相关文档：
  - `docs/HOST_PROTOCOL.md`
  - `docs/ARCHITECTURE.md`
- 相关代码路径：
  - `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/HostProtocol/`
  - `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/`
- 已知约束：
  - mutation snapshot 仍为 single-use。
  - 模型 ID 必须映射回 fresh snapshot token。
  - 完整当前树始终是权威数据。

## 风险

- 风险：stable ID 被误当成跨 snapshot dispatch identity。
- 缓解方式：wire 同时保留 opaque token，host dispatch 只接受当前 token。
- 风险：结构匹配错误地复用兄弟节点 ID。
- 缓解方式：匹配限制在 sibling list，并优先使用 AX identifier/结构身份。
- 风险：差分比完整树更长。
- 缓解方式：按实际渲染行数比较，超过完整树时选择 `full`。

## 里程碑

1. 恢复稳定 ID、变化排序与 full fallback 合同。
2. 接入 snapshot registry 与 `observe` wire payload。
3. 补齐 Swift/host tests、协议文档、history 与 agent pin。

## 验证方式

- 命令：
  - `swift test`
  - `npm --workspace @maka/computer-use test`
- 手工检查：
  - 首次 observe 无 `difference`。
  - 连续未变化 observe 为 `no-change`。
  - post-action host 只渲染 declared difference，显式 observe 仍渲染完整树。
- 观测检查：
  - stable ID 跨新 token 保持。
  - 新 ID 大于 baseline 最大值。
  - remove-only revision 只按一行 compressed range 计入预算。

## 进度记录

- [x] 完成稳定 revision 与 wire payload。
- [x] 完成差分预算、removed range 与 full fallback。
- [x] 完成 Swift 全量测试与 host 侧协议/渲染/backend 测试。
- [x] 更新协议、架构、质量和 history。

## 决策记录

- 2026-08-10：stable ID 只用于模型展示，不成为 dispatch key。
- 2026-08-10：完整 current elements 永远随 snapshot 返回，difference 只作为渲染提示。
- 2026-08-10：显式 observe 保持 full rendering，只有 immediate post-action observation 使用差分。
- 2026-08-10：remove change 不重复占用渲染预算，删除集合按 compressed range 计一行。
