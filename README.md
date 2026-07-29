# maka-cu

The native macOS execution layer for Maka's Computer Use.

This is a fork of [iFurySt/open-codex-computer-use](https://github.com/iFurySt/open-codex-computer-use)
(MIT, © 2026 Leo), an independent reimplementation of the Computer Use service
that ships inside Codex. Its accessibility snapshot is the best open one there
is; rebuilding that from scratch would have been rework.

Upstream's own README is kept as `UPSTREAM_README.md`.

## Why a fork rather than a dependency

Upstream is a complete product: a standalone MCP server with its own tool
surface, its own permission app, and its own on-screen cursor. Maka already has
all three, and has semantics upstream does not:

- an action is bound to the observation it was planned against, is single-use,
  and a spent one is refused — where upstream re-resolves an element index
  against a freshly taken snapshot at action time
- the full Anthropic `computer_20251124` action contract, because Maka serves
  models that emit it; upstream is shaped for Codex's own tool surface
- Electron and Chromium targets driven through page identity and DOM read-back
  rather than through accessibility alone

So what is taken is the executor: the accessibility snapshot, the dispatch core,
input synthesis, the SkyLight background-click path, and app discovery. What is
replaced is everything model-facing and everything host-facing, because Maka is
already both of those.

## Relationship to upstream

Upstream's effort concentrates on `AccessibilitySnapshot.swift`. That is the
file this fork keeps closest to upstream and tracks. The parts this fork
rewrites — dispatch binding, permission identity, the tool surface — are ones
upstream rarely touches. That asymmetry is what makes the fork sustainable
rather than a divergence that has to be re-merged forever.

Improvements to the shared accessibility layer belong upstream, not here.

## Attribution

- Forked from `iFurySt/open-codex-computer-use` at `a265277` (v0.3.0,
  2026-07-27), MIT.
- The `sky_click` event recipe and the private SkyLight bridge originate in
  [trycua/cua](https://github.com/trycua/cua) (MIT) and yabai. See
  `THIRD_PARTY_NOTICES.md`, inherited unchanged.
- Behaviour recovered from Codex's shipped binary is reimplemented, never
  copied: that binary is proprietary and confers no license. The archived
  copies upstream kept under `docs/references/.../assets/` are removed here
  rather than redistributed.
