# 技术债追踪

这里记录那些暂时不阻塞当前任务、但已经值得留档的技术债。

| 日期 | 区域 | 债务描述 | 为什么会存在 | 计划中的后续动作 |
| --- | --- | --- | --- | --- |
| 2026-04-17 | 普通 app AX snapshot | Finder 路径已经能拿到前台窗口子树并输出 window-relative frame，但当前还缺更多真实 app 回归样本，无法证明这套 rooting / traversal 对复杂 app 都稳定。 | 这一轮先把 Finder 这类真实 app 的坐标换算和窗口子树收敛好，再把 deterministic 回归继续留给 fixture。 | 增加 Safari / System Settings / Activity Monitor 等真实 app 样本验证，并继续收敛 `kAXMainWindowAttribute`、focused element parent chain 和多窗口回退策略。 |
| 2026-08-10 | 标准 MCP adapter | Kimi 的本地 stdio MCP 入口值得吸收，但当前 `create-mcp-use-app` 默认依赖不存在的 `mcp-use@2.0.0-beta.68`；可安装的 beta.66 只提供 HTTP 主线，依赖审计有 8 个 high severity，不能直接进入 Maka 主仓库。 | 先保持 executor 只说 `maka.cu/2`，避免重新复制 model-facing 语义。 | 等 mcp-use 有可安装稳定版与 stdio transport，或建立独立 adapter repo；adapter 只翻译 MCP 到 `maka.cu/2`，不得重新实现 AX/index/fallback。 |
