# open-computer-use

`open-computer-use` 是一个开源的 `Computer Use` 服务，已经包装成 `MCP` 协议，支持所有的AI Agent或MCP Client快速调用实现 `Computer Use` 的能力。

项目的背后是 OpenAI 刚发布的 [Codex Computer Use](https://openai.com/index/codex-for-almost-everything/) ，让我看到了基于 Accessibility 可以实现非抢占式的CUA能力，因此决定复刻一个开源版本。

在这期间我利用了之前写[harness的模版](https://github.com/iFurySt/harness-template)开启了这个新的项目，这是一个template可以快速拉起一个面向AI的repo，非常适合100% AI-Generated的项目，也是这一个月来我们最大的实践和收获，现在我们可以基于这套方法论快速实现任何的东西，有兴趣的可以自己尝试一下，我也写了一片[文章](https://www.ifuryst.com/blog/2026/speedrunning-the-ai-era/)专门介绍这套方法论的

## Quick Start

先全局安装：

```bash
npm i -g open-computer-use
```

第一次使用前，给宿主终端或客户端授予 macOS 的 `Accessibility` 和 `Screen Recording` 权限；不确定当前状态时，直接运行：

```bash
open-computer-use doctor
```

接着把它配到你的 MCP client 里：

```json
{
  "mcpServers": {
    "open-computer-use": {
      "command": "open-computer-use",
      "args": ["mcp"]
    }
  }
}
```

## 更多

除了直接用上面的 MCP JSON 配置，你也可以用一些内置子命令：

```bash
# 一键安装到Claude，写到~/.claude.json中
open-computer-use install-claude-mcp
# 一键安装到Codex，写到~/.codex/config.toml中
open-computer-use install-codex-mcp
# 一键安装到Codex插件，主要方便在Codex App中使用，有装这个就不需要重复装codex-mcp了，写到~/.codex/plugins/cache/openai-bundled/computer-use/和~/.codex/config.toml中
open-computer-use install-codex-plugin
# 直接启动MCP server
open-computer-use mcp
# 检查权限并在缺失时拉起引导
open-computer-use doctor
# 查看帮助
open-computer-use -h
```

## License

[MIT](./LICENSE)。
