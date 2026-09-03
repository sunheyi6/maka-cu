<!--
  Licensed to the Apache Software Foundation (ASF) under one
  or more contributor license agreements.  See the NOTICE file
  distributed with this work for additional information
  regarding copyright ownership.  The ASF licenses this file
  to you under the Apache License, Version 2.0 (the
  "License"); you may not use this file except in compliance
  with the License.  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing,
  software distributed under the License is distributed on an
  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
  KIND, either express or implied.  See the License for the
  specific language governing permissions and limitations
  under the License.
-->

# Rust/direct-COM Windows executor

This started as the comparison prototype for `apache/maka#4318` and is now the
source baseline for the native executor being moved to
`maka-cu/apps/OpenComputerUseWindows/native`. It speaks the shared `maka.cu/2`
line-delimited JSON-RPC protocol; it does not define a private Windows wire
schema.

The Windows build uses the `windows` crate only as a typed ABI declaration: UI
observation and actions call `IUIAutomation`/`IUIAutomation*Pattern` COM
interfaces directly. It supports:

* `host.hello`, session ownership, and explicit top-level window enumeration;
* bounded UIA observation with HWND/PID/generation identity;
* one-use opaque snapshot/element tokens;
* `ValuePattern.SetValue` and `InvokePattern.Invoke` semantic actions;
* focus-bound `dispatch.key` for the closed `maka.cu/2` key vocabulary and
  modifiers. It revalidates the quoted HWND/PID/process-start time/window
  generation and UIA focus before `SendInput`; delivery without an
  application-level readback remains `unknown`;
* target-window and whole-display `screen.capture` backed by
  `IGraphicsCaptureItemInterop::CreateForWindow(HWND)` and D3D11 staging
  readback (bounded PNG/base64; no GDI, screen-rectangle, or covering-pixel
  fallback); and
* EOF/shutdown boundaries with no global-pointer, coordinate, PostMessage, or
  screen fallback path.

The observation response includes both the compact `elements` list and the
driver-compatible `tree.nodes` view. Each live element carries the UIA
`RuntimeId`; action revalidation refuses to rematch a replacement by title,
index, or automation id. The target identity also records the owning PID,
process creation FILETIME, HWND, and UIA root RuntimeId fingerprint.

Capture is implemented only on Windows: the endpoint creates a WGC item from
the supplied HWND, captures a frame, copies it through a CPU-readable D3D11
staging texture, and returns a bounded PNG/base64 payload. It is tied to the
same `windowGeneration` checked by `observe`; a lost/changed target returns the
typed `capture_unavailable` result. On non-Windows or when WGC is unavailable,
the result is explicitly unavailable rather than a screen fallback.

Snapshot and image ownership are explicit. A live snapshot is valid for 120
seconds; a newer observation of the same window supersedes it, and the session
evicts the oldest live snapshot after eight. Spent, superseded, expired, and
evicted snapshots each delete their owned image before returning their distinct
protocol error. `screen.capture` images are session-owned, expire on the same
120-second clock, and are deleted by `session.end`. The executor tracks its own
image bytes, evicts the oldest owned file when necessary, and refuses a write
that still would exceed the 256 MiB image-directory budget.

## Build and verification

Use Cargo from `PATH`:

```powershell
cargo fmt -- --check
cargo test --locked --all-targets --manifest-path apps/OpenComputerUseWindows/native/Cargo.toml
cargo clippy --locked --all-targets --manifest-path apps/OpenComputerUseWindows/native/Cargo.toml -- -D warnings
cargo build --locked --release --manifest-path apps/OpenComputerUseWindows/native/Cargo.toml
```

The protocol tests cover snapshot TTL, one-use dispatch, supersede/evict
states, session cleanup, image ownership and budget, and bounded observations.
The CI workflow repeats these checks on Windows and Linux analysis targets and
records the Windows artifact digest against `GITHUB_SHA`. Clean-machine
validation, Authenticode signing, and packaged conversation E2E are still
release-qualification work; `distributionReady` must remain false until all
three are tied to the same artifact.

## Safety and lifecycle boundary

The helper never selects a window by title or foreground state for an action;
the host must provide the HWND. Keyboard `focusPolicy=acquire` may bring that
explicitly supplied HWND to the foreground only after the quoted identity is
revalidated; `focusPolicy=require` never takes focus. An observe creates a
registry entry, and `dispatch.element` spends that entry before revalidating the
target and dispatching the COM pattern. A repeated token therefore fails closed
as `snapshot_spent`; a superseded, expired, or evicted token reports its
corresponding lifecycle code. A token from a restarted or ended executor remains
`snapshot_unknown`, while a recreated/changed target fails as `window_gone`,
`process_replaced`, or `element_changed`.
Mutation results are verified by the platform operation's readback category;
the prototype does not retry unknown mutations. Stdio/control runs on its own
thread while a dedicated worker owns the MTA UIA apartment. Cancellation before
dispatch spends an `act` snapshot without touching COM; cancellation after
dispatch reports cancellation intent while allowing the original operation to
settle. A blocked COM provider still requires the host supervisor to kill the
helper after the 2-second grace period; EOF and shutdown are bounded and do not
wait for that worker.
