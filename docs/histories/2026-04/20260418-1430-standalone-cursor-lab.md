## [2026-04-18 14:30] | Task: 落独立 cursor motion lab

### 🤖 Execution Context
* **Agent ID**: `codex`
* **Base Model**: `gpt-5`
* **Runtime**: `Codex CLI`

### 📥 User Query
> 结合官方视频和已分析到的 cursor overlay 线索，在当前仓库里单独开一个目录，实现一版可独立开源的软件鼠标曲线，并继续推进分析与落地。

### 🛠 Changes Overview
**Scope:** `Package.swift`、`experiments/StandaloneCursorLab/`、`docs/`、`README`

**Key Actions:**
- **[新增独立 target]**: 把 `StandaloneCursorLab` 加入 Swift Package，可通过 `swift run StandaloneCursorLab` 单独运行。
- **[实现 motion demo]**: 新增参数化 cursor motion model、Bezier 路径生成、spring/timing 模拟和 SwiftUI 调参界面。
- **[补齐点击交互]**: 支持点击画布任意位置生成多条候选路径，并选中一路径驱动 cursor 动画。
- **[收敛候选曲线与显示逻辑]**: 扩展为多组 descriptor 驱动的轨迹族，并让主路径在关闭 `DEBUG` 时继续可见。
- **[修正点击坐标与死区]**: 统一 AppKit click-capture 和 SwiftUI 画布的坐标语义，去掉误导性的矩形事件排除区，避免底部区域出现“点了不动”的隐藏死区。
- **[收敛 demo 控件状态]**: 把 `DEBUG` toggle 的开启态改为明确高亮，并让顶部 controls 只占自身区域，不再靠整层透明容器遮挡画布事件。
- **[增强 turn/brake 手感]**: 把路径生成从“只看起终点连线”改成“线方向 + cursor 朝向”的混合约束，并新增 `turn` / `brake` family，让主路径更容易出现先顺头部方向、再掉头切入、末端带刹车回咬的走势。
- **[重做 timing / rotation]**: 把进度推进从 spring + `easeInOut` 改成更接近人手 pointing 的 minimum-jerk bell-shaped timing；同时让 cursor 在运动过程中持续朝向切线方向，并在到点阶段平滑回归经典朝向。
- **[移除末端多余位移]**: 删除位置层的 settle overshoot，保留连续移动和自然减速，不再在最后额外挪一下。
- **[加入 curvature-aware timing]**: 为路径建立 weighted-effort lookup，把高曲率和大 heading-change 的片段映射为更慢的时间推进，让“起步掉头”和“末端收束”阶段获得更自然的速度分配，而不是直接用 Bezier 参数 `t` 均匀走完。
- **[切到资源化 cursor asset]**: 把 standalone lab 的矢量箭头切换为 target 内置 PNG 资源，建立单独的 glyph calibration，并把静止姿态收敛到接近视频里的默认朝向。
- **[改为 tip-anchor 命中对齐]**: 不再拿整张 cursor 图的中心做定位，而是把图像 tip 对齐到 motion sample point，避免更换为朝上型 asset 后重新出现点击坐标偏移。
- **[收敛运动中朝向跟随]**: 把 motion simulator 的 rotation 统一为基于 glyph neutral heading 的绝对姿态，运动时持续追随曲线切线方向，结束时再平滑回到静止角度。
- **[同步仓库知识]**: 补 motion model 逆向分析文档、active execution plan、架构说明、README 入口和 history。

### 🧠 Design Intent (Why)
主线 `SoftwareCursorOverlay` 更适合承载产品行为，不适合继续堆调参与实验 UI。这次把 cursor 曲线实验拆成独立 lab，是为了先稳定参数模型和视觉手感，再决定哪些部分适合回灌主 MCP 实现或单独开源。

### 📁 Files Modified
- `Package.swift`
- `README.md`
- `README.zh-CN.md`
- `docs/ARCHITECTURE.md`
- `docs/exec-plans/active/20260418-standalone-cursor-lab.md`
- `docs/references/codex-computer-use-reverse-engineering/README.md`
- `docs/references/codex-computer-use-reverse-engineering/software-cursor-motion-model.md`
- `experiments/StandaloneCursorLab/README.md`
- `experiments/StandaloneCursorLab/Sources/StandaloneCursorLab/CursorMotionModel.swift`
- `experiments/StandaloneCursorLab/Sources/StandaloneCursorLab/CursorLabRootView.swift`
- `experiments/StandaloneCursorLab/Sources/StandaloneCursorLab/StandaloneCursorLabApp.swift`
