# 发版指南

这份文档约束这个仓库未来的 patch / minor release 流程，目标是避免再次出现 “git tag 已经发了，但 npm staging 产物版本还是旧值” 这类版本源不一致问题。

## 什么时候必读

- 只要任务里包含这些动作之一，就先读这份文档：
  - bump 版本
  - 打 release tag
  - 推送 release tag
  - 看 GitHub Actions release 失败原因
  - 重发某个失败版本

## 当前 release 入口

- 本地 staging / 打 tgz：`./scripts/release-package.sh`
- 本地 stage npm 包目录：`node ./scripts/npm/build-packages.mjs`
- 本地 publish：`node ./scripts/npm/publish-packages.mjs`
- CI workflow：`.github/workflows/release.yml`
- 用户可见发布记录：`docs/releases/feature-release-notes.md`

## 当前版本源

这个仓库的 npm staging 包版本，当前以 `plugins/open-computer-use/.codex-plugin/plugin.json` 里的 `version` 为准。

也就是说：

- 只改 git tag，不改这个 manifest，不会得到新 npm 版本。
- `scripts/npm/build-packages.mjs` 会从这个 manifest 读取版本，再生成三个 staging 包。
- 所以 release 前必须先把这份 manifest bump 到目标版本。

## Release Checklist

### 1. 先统一版本号

至少检查并同步这些位置：

- `plugins/open-computer-use/.codex-plugin/plugin.json`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/OpenComputerUseVersion.swift`
- `apps/OpenComputerUseSmokeSuite/Sources/OpenComputerUseSmokeSuite/main.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `scripts/computer-use-cli/main.go`
- `scripts/computer-use-cli/README.md`
- `docs/releases/feature-release-notes.md`
- `docs/histories/` 中本轮 release 对应的 history

如果这轮 release 还改了其他对外暴露版本字符串，也要一起对齐，不要只改一半。

### 2. 本地验证版本源已经生效

至少跑这两步：

```bash
swift test
node ./scripts/npm/build-packages.mjs --skip-build --out-dir dist/release/npm-staging-check
```

然后直接检查 staging 包版本：

```bash
node -p "require('./dist/release/npm-staging-check/open-codex-computer-use-mcp/package.json').version"
```

如果这里打印的不是目标版本，不要打 tag。

### 3. 提交版本 bump

- 用单独 commit 提交 release version bump。
- commit message 要能直接看出这是 release 收口，而不是普通功能提交。

### 4. 打 tag 并推送

当前约定用 `vX.Y.Z`：

```bash
git tag -a v0.1.12 -m "v0.1.12"
git push origin main
git push origin v0.1.12
```

## Release 失败时怎么查

### 1. 先看最新 run

```bash
gh run list -R iFurySt/open-codex-computer-use --limit 10
gh run view -R iFurySt/open-codex-computer-use <run-id> --log-failed
```

### 2. 重点看哪一类错误

- `npm error 403 ... You cannot publish over the previously published versions`
  - 通常不是 token 权限问题，而是 staging 包版本仍然是旧版本。
  - 先回头检查 `plugin.json` 的 `version`，再检查 staging 包实际产出的 `package.json`。
- 构建阶段失败
  - 优先看 `Build npm release artifacts` 或 Swift 编译错误。
- publish 认证失败
  - 再去看 `.github/workflows/release.yml`、`scripts/npm/publish-packages.mjs` 和 npm trusted publishing / token fallback 配置。

## 如果 tag 已经打错了

如果远端 tag 已经指向错误 commit，先删 tag，再修版本源，再重打。

本地删 tag：

```bash
git tag -d v0.1.12
```

远端删 tag：

```bash
git push origin :refs/tags/v0.1.12
```

修好后再重新创建并推送同名 tag。

## 文档同步要求

每次 release 都至少同步这三类文档：

- `docs/releases/feature-release-notes.md`
- `docs/histories/` 对应 release history
- 如果 release 流程本身有变化，这份 `docs/releases/RELEASE_GUIDE.md`

如果一次 release 暴露出新的流程坑，就不要只在聊天里记住，直接补进这份文档。
