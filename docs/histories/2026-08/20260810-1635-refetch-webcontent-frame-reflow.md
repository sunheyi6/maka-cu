## [2026-08-10 16:35] | Task: Recover direct WebContent frame reflow

### Execution Context

- Agent: Codex
- Runtime: Codex desktop

### User Query

> Implement the Web Computer Use surface first and review it in parallel before
> merging.

### Changes

- Direct renderer-owned bindings now allow a unique identity-preserving refetch
  when the only live digest change is `frame`; native AX bindings remain strict.
- A refetched renderer-owned binding retains WebContent classification, so a
  left click continues through `skylight_pid`.
- Test snapshot support now records frame and optional renderer generation
  inputs.
- The focused regression uses a direct WebContent binding and asserts the
  trusted renderer path and renderer PID.

### Root Cause

The host-mirror promotion branch already tolerated a frame-only renderer reflow,
but a snapshot that directly exposed the WebContent element entered the initial
binding verification branch. A live retained AX object with a changed frame was
therefore refused immediately as `element_changed`, before the existing unique
refetch logic could establish the same semantic target at its new geometry.

### Safety Boundary

Only the exact changed-field set `["frame"]` is eligible. The existing refetch
still requires a unique semantic identity in the same host and renderer process
generations. Other digest changes, missing targets, and ambiguous candidates
remain fail closed.
