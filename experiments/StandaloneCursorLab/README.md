# Standalone Cursor Lab

这个目录用于实现一个可独立演进、后续可单独开源的软件 cursor motion demo。

当前目标不是替换仓库主线的 `SoftwareCursorOverlay`，而是先把“轨迹几何 + 时序弹性 + 调参 UI”从主产品代码里拆出来，做成一个更适合试验和对比的视频 lab。

## 为什么单独放这里

- 主线 `packages/OpenComputerUseKit/.../SoftwareCursorOverlay.swift` 已经承担产品行为，不适合继续塞大量实验代码。
- 用户提供的视频和官方字符串都说明 cursor motion 有独立参数模型，适合先做一个 lab。
- 这块后续可能单独开源，先在目录边界上收口更干净。

## 计划中的模块

- `Sources/MotionModel/`
  - 参数定义，例如 `startHandle`、`endHandle`、`arcSize`、`arcFlow`、`spring`
- `Sources/PathBuilder/`
  - 根据起点、终点和参数生成可采样曲线
- `Sources/Simulator/`
  - 负责路径进度、spring settle、timing
- `Sources/App/`
  - 本地 demo UI、debug slider、toggle、目标点交互

## 当前参考

- `docs/references/codex-computer-use-reverse-engineering/software-cursor-overlay.md`
- `docs/references/codex-computer-use-reverse-engineering/software-cursor-motion-model.md`
- `docs/exec-plans/active/20260418-standalone-cursor-lab.md`

## 当前状态

当前已经有一个可运行的 SwiftUI demo target：

```bash
swift run StandaloneCursorLab
```

现阶段支持：

- 点击画布任意位置，先预览多条候选路径，再自动选一路径并驱动 cursor 过去。
- 拖动起点和终点。
- 实时调 `START HANDLE`、`END HANDLE`、`ARC SIZE`、`ARC FLOW`、`SPRING`。
- 预览 Bezier 主路径、控制柄和 cursor 动画。
- 使用 target 自带资源里的 cursor asset 渲染指针，并用 tip-anchor 而不是整张图中心来对齐点击点。
- cursor 在运动过程中持续跟随当前切线方向，结束后再回到静止姿态。

后续实现应优先保持：

- 参数层不依赖 AppKit。
- 几何层和时间层分离。
- demo host 可以替换，但 motion model 可以单独复用。
