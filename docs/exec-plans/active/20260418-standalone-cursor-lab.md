# Standalone Cursor Lab

## 目标

在当前仓库内落一个与主 `OpenComputerUseKit` 解耦的独立目录，用 Swift 实现一版可调参的软件 cursor motion demo，用来逼近官方视频里的手感，并为后续单独开源做准备。

## 范围

- 包含：
- 新建独立目录承载 cursor motion 实验，不直接污染主 MCP runtime。
- 把 motion model 拆成参数层、路径层、时间模拟层、渲染层。
- 做一个本地可运行的 demo，至少支持起点/终点、轨迹预览、参数滑杆和点击触发。
- 把本轮逆向分析沉淀到 `docs/references/`。
- 不包含：
- 本轮不要求接入真实 `click` tool。
- 本轮不要求完全复刻官方闭源素材。
- 本轮不要求把 demo 立即发布成独立仓库。

## 背景

- 用户提供了 X 视频样本，明确出现 `START HANDLE`、`END HANDLE`、`ARC SIZE`、`ARC FLOW`、`SPRING` 调参项。
- `SkyComputerUseService` 字符串已出现 `BezierParameters`、`SpringParameters`、`arcHeight`、`arcIn`、`arcOut`、`cursorMotionProgressAnimation` 等证据。
- 当前仓库已有 `SoftwareCursorOverlay.swift`，但它更像产品内近似实现，不适合继续承载大量调参与实验 UI。

## 风险

- 风险：过早把实验代码下沉到主包，导致主线 overlay 行为反复波动。
- 缓解方式：先放独立目录，稳定后再抽公共模块。
- 风险：只凭视频调参，可能把“视觉像”误当成“结构对”。
- 缓解方式：优先围绕已确认字段名建模，不做纯拍脑袋参数命名。
- 风险：demo UI 和未来独立开源边界不清。
- 缓解方式：第一阶段只做最小可运行 lab，避免提前引入和 MCP/tool 相关的耦合。

## 里程碑

1. 建立独立目录与 README，明确模块边界。
2. 实现纯参数化路径生成与可视化。
3. 补 spring/timing 模拟。
4. 视效果再决定是否回灌主 overlay。

## 验证方式

- 能独立运行本地 demo。
- 能通过 slider 实时改变轨迹几何和停驻手感。
- 仓库文档能说明该目录与主产品代码的边界。

## 进度记录

- [x] 里程碑 1
- [x] 里程碑 2
- [x] 里程碑 3
- [ ] 里程碑 4

## 最新进展

- 2026-04-18：已补齐点击任意位置触发候选路径预览，不再局限于 replay。
- 2026-04-18：已修正 click capture 的坐标系和事件覆盖问题，底部区域不再因为额外矩形排除区而出现隐藏死区。
- 2026-04-18：已把 `DEBUG` toggle 的开启态改成明显高亮，并把 controls 改成最小 overlay 布局，避免透明容器阻挡画布点击。
- 2026-04-18：已把路径模型升级为“line direction + cursor heading”混合约束，并新增 `turn` / `brake` 候选族，选中的主路径开始具备更明显的先顺头部方向、再回咬目标的走势。
- 2026-04-18：已把 timing 从 spring + `easeInOut` 改为 minimum-jerk bell-shaped profile，并移除位置层末端 overshoot；cursor 在运动中持续跟随切线朝向，到点阶段再平滑回正。
- 2026-04-19：已为路径建立 curvature / heading-change 加权的 effort lookup，进度推进不再直接绑定 Bezier 参数 `t`，从而让高曲率转向段更慢、直线段更快。
- 2026-04-19：已把 standalone lab 的 cursor 切到资源化 PNG asset，并改成 tip-anchor 驱动的命中点对齐；静止姿态与运动姿态共用一套 heading calibration，运动中持续朝向当前切线方向。

## 决策记录

- 2026-04-18：先把这项工作定义为 standalone lab，而不是继续直接堆进 `OpenComputerUseKit`.
- 2026-04-18：参数命名优先采用视频 UI 与官方字符串的交集：`start/end handle`、`arc size/flow`、`spring`。
- 2026-04-18：第一版 demo 先用独立 SwiftUI target + `CVDisplayLink` 驱动模拟，优先验证参数语义和轨迹手感，再考虑与主 overlay 合流。
