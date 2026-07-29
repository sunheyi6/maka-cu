# maka-cu Host Protocol (`maka.cu/1`)

The wire contract between the Maka Electron host (TypeScript) and `maka-cu`, the
native macOS executor (Swift). Both sides are ours. This protocol answers to
`CuDispatchBackend` in `packages/runtime/src/computer-use-types.ts` and to
nothing else.

It replaces `maka-cu`'s MCP surface (`MCPServer.swift`, `ToolDefinitions.swift`,
`ComputerUseToolDispatcher.swift`). It is not MCP, carries no tool schemas and no
model-facing prose: Maka's runtime owns every word the model reads.

Two engineers who cannot talk to each other should be able to build the two ends
from this document and have them interoperate. Where a rule exists because of a
specific bug or measurement, the rule says so.

---

## 1. Framing

Line-delimited JSON-RPC 2.0 over the executor's stdin/stdout. One JSON value per
line, UTF-8, terminated by `\n`. No `Content-Length` headers. This is what
`MCPServer.swift:27-37` already reads and what
`packages/computer-use/src/cua-driver-service.ts:395-416` already parses; the new
protocol does not differ gratuitously in framing, only in payload.

- stdout carries JSON-RPC and nothing else. Any diagnostic, warning or panic goes
  to stderr. A non-JSON line on stdout is a protocol violation; the host drops it
  and counts it, and three in one process generation are grounds for teardown.
- Every request has an integer `id`. Notifications have no `id`.
- Responses MAY arrive out of order. The host correlates by `id` only. This is
  already true of the host implementation and is stated here so the executor is
  free to use lanes (§9) without a framing change when the capture stream lands.
- Maximum encoded message size is `limits.maxResponseBytes` (§3). A response that
  would exceed it MUST NOT be truncated silently — see §7.6.
- The executor MUST emit exactly one response per request `id` it has read, and
  MUST NOT emit a response for an `id` it never received.

### 1.1 Result envelope

Two error layers, deliberately separated.

**JSON-RPC `error`** means the *request* was unusable or the executor was not in a
state to consider it. It never describes the world.

| code | meaning |
| --- | --- |
| `-32700` | parse error |
| `-32600` | invalid request (not JSON-RPC 2.0) |
| `-32601` | unknown method |
| `-32602` | invalid params (missing field, wrong type, value outside a closed set) |
| `-32603` | internal executor error |
| `-32000` | `protocol_version_mismatch` (§2) |
| `-32001` | `handshake_required` — a method other than `host.hello` arrived first |
| `-32002` | `session_unknown` — `session` names a session that was never begun or has ended |
| `-32003` | `shutting_down` — SIGTERM received, no new work accepted |

**JSON-RPC `result`** carries everything about the world, as a tagged union:

```json
{ "ok": true,  ...method-specific fields }
{ "ok": false, "error": { "code": "<domain code>", "message": "<fixed sentence>", "detail": { } } }
```

Domain failures (snapshot spent, element changed, permission missing, dispatch
refused) are results, not JSON-RPC errors. They are expected outcomes the model
must see, they carry structured evidence, and a JSON-RPC error object has only
`code`/`message`/`data` — which invites exactly the free-form-field archaeology
this protocol exists to end.

### 1.2 No application text outside declared observation fields

`error.message` is a fixed sentence chosen by `error.code`. `error.detail`
contains enums and numbers only. The only fields in this protocol that may carry
text belonging to the observed application are `element.label`,
`element.value`, `element.placeholder`, `element.axIdentifier`,
`snapshot.target.title`, `snapshot.selectedText.text`, and `app.name` —
all of which the host already treats as untrusted content.

This is a change of posture. The current backend carries a comment that
`cua-driver does NOT redact secrets — the runtime redacts every backend-supplied
message upstream` (`cua-driver-backend.ts:15-16`). Under this protocol the
executor never puts application content in a diagnostic string, so there is no
message-redaction pass to get wrong.

---

## 2. Handshake

`host.hello` MUST be the first message on the connection. Anything else gets
`-32001`.

**Request**

```json
{
  "jsonrpc": "2.0", "id": 1, "method": "host.hello",
  "params": {
    "protocol": "maka.cu/1",
    "host": { "name": "maka", "version": "0.9.3" },
    "hostPid": 8123,
    "imageDir": "/var/folders/…/maka-cu-images-8123",
    "allowGlobalPointer": false
  }
}
```

- `protocol` — exact string. No negotiation, no "highest common version".
- `hostPid` — the executor polls `kill(hostPid, 0)` every 2s and exits if the
  host is gone. macOS has no `PDEATHSIG`; without this an orphaned executor
  holding Accessibility survives a host crash.
- `imageDir` — absolute, must already exist and be writable by the executor.
  Every image reference in this protocol is a path under this directory (§8).
  The executor MUST verify writability during the handshake and fail it
  otherwise; discovering the directory is read-only at first `observe` would
  turn a configuration error into a capture failure.
- `allowGlobalPointer` — when `false` (the only value Maka ships), the executor
  MUST NOT use any dispatch path that moves the system cursor or changes window
  z-order, and MUST refuse rather than fall back to one. See §6.3.

**Result**

```json
{
  "ok": true,
  "protocol": "maka.cu/1",
  "executor": { "name": "maka-cu", "version": "0.4.0", "commit": "1747868" },
  "pid": 8140,
  "capabilities": {
    "captureStream": false,
    "elementActions": ["click", "set_value", "select_text", "secondary_action", "scroll"],
    "pointActions": ["move", "left_click", "right_click", "middle_click", "double_click",
                     "triple_click", "mouse_down", "mouse_up", "drag", "scroll"],
    "keyActions": ["type", "key"],
    "imageFormats": ["png", "jpeg"]
  },
  "limits": {
    "snapshotsPerSession": 8,
    "snapshotTtlMs": 120000,
    "maxElements": 1500,
    "maxDepth": 64,
    "maxTextChars": 500,
    "maxResponseBytes": 1048576,
    "settleCeilingMs": 2500,
    "shutdownGraceMs": 3000,
    "imageDirBudgetBytes": 268435456
  }
}
```

Every limit here has a host consumer: the host must not hardcode a bound the
executor enforces. Today the host duplicates all of them —
`MAX_OBSERVATIONS_PER_SESSION = 16`, `SETTLE_CEILING_MS = 2_500`,
`max_elements: 500` at four call sites — and nothing detects drift when the
executor's number changes.

**Version mismatch is fatal and loud.** If `params.protocol` is not a version the
executor implements, it MUST answer

```json
{ "jsonrpc": "2.0", "id": 1,
  "error": { "code": -32000, "message": "protocol_version_mismatch",
             "data": { "supported": ["maka.cu/1"] } } }
```

then flush stdout and exit with status `78` (`EX_CONFIG`). The host MUST classify
this as `service_mismatch` and MUST NOT retry — `CuaDriverService.startWithBudget`
already treats `service_mismatch` as non-retryable
(`cua-driver-service.ts:200-203`). Silent degradation to a subset is forbidden in
both directions.

---

## 3. Sessions

A session is the host's unit of ownership: snapshots, images, keyboard target
and capture streams all belong to one. The host supplies the id, because Maka
already has one (`CuRunContext.sessionId`) and a second identity space would
have to be joined by hand.

### `session.begin`

```json
{ "method": "session.begin",
  "params": { "session": "s-01J…", "captureScope": "window" } }
```

`captureScope` ∈ `"window" | "desktop"`. It selects the ScreenCaptureKit content
filter for the life of the session and cannot be changed afterwards.

```json
{ "ok": true }
```

Beginning a session id that is already live is `-32602`, not an implicit reset:
an accidental reuse must not silently discard live snapshots.

### `session.end`

```json
{ "method": "session.end", "params": { "session": "s-01J…" } }
```

```json
{ "ok": true, "released": { "snapshots": 3, "images": 3, "streams": 0 } }
```

Drops every snapshot, deletes every image file the session produced, stops every
capture stream, releases the keyboard target, and removes any executor-drawn
cursor. `released` is reported because Maka has already been bitten by an agent
cursor outliving the run that drew it
(`cua-driver-service.ts:717-726`); a count the host can assert on is how that
regression gets a test.

Ending an unknown session is `ok: true` with zero counts, not an error —
teardown must be idempotent.

---

## 4. Frame binding

This is the reason the protocol exists. Upstream `cua-driver` re-resolves an
element *index* against a snapshot taken at action time, so "click element 7"
means "click whatever is 7 now". Maka compensates today by re-fetching the whole
window state and re-matching on role/label/value/frame/depth in TypeScript
(`cua-driver-target-resolution.ts:522-592`) — a check that costs an extra AX
tree walk per action and still cannot see anything the driver did not print.

Here the executor owns it.

### 4.1 Snapshot lifecycle

`observe` mints a snapshot: an id, a set of element tokens, and — held inside the
executor — the retained `AXUIElement` references and recorded digests.

A snapshot is in exactly one state:

| state | entered when | dispatch quoting it fails with |
| --- | --- | --- |
| `live` | created by `observe` or by a dispatch's post-observation | — |
| `spent` | a dispatch quoting it returned `ok:true` with a mutating method, or returned `outcome_unknown` | `snapshot_spent` |
| `superseded` | a later `observe` produced a snapshot of the same `(pid, windowId)` | `snapshot_superseded` |
| `expired` | `limits.snapshotTtlMs` elapsed since `capturedAt` | `snapshot_expired` |
| `evicted` | more than `limits.snapshotsPerSession` live snapshots in the session; oldest goes first | `snapshot_evicted` |
| unknown | never existed in this process | `snapshot_unknown` |

Five distinct codes, not one. They mean different things to the host: `spent` and
`superseded` mean *re-observe and retry*, `evicted` means *the host is holding
too many frames*, `unknown` after a restart means *the executor died*, and
collapsing them is how a retry loop becomes indistinguishable from a bug.

Notes:

- A **refused** dispatch does not spend its snapshot. The host may fix the
  argument and retry against the same frame. The single exception is
  `outcome_unknown`, which spends it: we cannot prove the action did not land.
- A **read** does not spend a snapshot. `screen.capture` and `window.list` never
  touch snapshot state.
- Supersession is scoped to `(pid, windowId)`. Observing window B does not
  invalidate a live snapshot of window A. **The executor is deliberately more
  permissive than the host here:** `CuaFrameState` keeps exactly one current
  frame globally and invalidates on every observe
  (`cua-frame-state.ts:47-56`). Host policy still binds; the executor does not
  re-implement it, so neither side should assume the other is enforcing the
  single-frame rule.
- Snapshot ids MUST contain a 128-bit per-process nonce. After a restart, an id
  minted by the previous generation must fail `snapshot_unknown` and must never
  collide with a fresh one.

### 4.2 Element tokens

Each element in a snapshot carries a `token`: an opaque string, unique within the
executor process, meaningful only inside its own snapshot.

The executor MUST look tokens up by exact string match in a per-snapshot
dictionary. It MUST NOT parse an index out of a token and re-walk the tree. An
index-derived token that survives a tree rebuild is precisely the defect being
removed.

### 4.3 What "the same element" means

A token resolves to the same element at dispatch time if and only if all three
hold:

- **E1 — the reference is alive.** The retained `AXUIElement` answers an attribute
  read with something other than `kAXErrorInvalidUIElement`.
- **E2 — the process is the same process.** The recorded `pid` still exists and
  its start time (`proc_pidinfo` / `p_starttime`) is unchanged. A recycled pid
  fails.
- **E3 — the digest matches.** The recomputed element digest equals the digest
  recorded at observe time.

Element digest = SHA-256 over the canonical JSON array

```
[ role, subrole, axIdentifier, title, label, valueDigest,
  frameInWindow, sortedActionNames, ancestorRoles[0..7], siblingIndex ]
```

`valueDigest` is `null` when the element has no value, otherwise SHA-256 of the
**untruncated** value string. Digesting the untruncated value matters: the wire
value is capped at `limits.maxTextChars`, and digesting the capped copy would
make every edit past character 500 invisible to the check.

Ancestor roles are capped at 8 levels root-ward. Sibling index is the element's
position among its parent's traversed children.

The digest is exposed to the host as `element.digest`, and the host MUST echo it
in every element dispatch (§6.1). Echoing is not redundant with the executor's
own record: it catches a host that has mixed up two elements from two snapshots,
which the executor's record by construction cannot.

Window digest = SHA-256 over the sorted set of every element's digest, plus the
window bounds and title. Exposed as `snapshot.windowDigest` and echoed by point
dispatch (§6.3), which has no element to anchor to.

### 4.4 What this check cannot catch

Stated plainly, because a binding check that is trusted beyond its reach is worse
than none.

1. **Recycled views.** `NSTableView` and `NSOutlineView` reuse row views. One
   `AXUIElement` can come to represent a different data row after a scroll. If a
   list scrolls by exactly one row height and the new occupant has the same role,
   label, value and frame, E1–E3 all pass and the click lands on the wrong
   record. Nothing available through Accessibility distinguishes them. The host's
   only defence is `strictness: "window"` (§6.1), which refuses when anything in
   the window changed — correct for lists, far too strict for a window with a
   clock in its toolbar. The protocol makes it the host's declared choice rather
   than a guess by either side.

2. **Tree-rebuilding applications.** Chromium and Electron web areas mint fresh
   `AXUIElement`s per query. There E1 can fail on a control that is visibly still
   present and unchanged. This is a **false refusal**, not a false accept, and it
   is why `element_released` is its own code: the correct host response is to
   re-observe, not to tell the user the control vanished.
   `maka-cu` already carries Electron-specific click handling
   (`ComputerUseService.swift:372-413`), which is evidence that this app class is
   the hard one — but the invalidation rate has not been measured. See open
   questions.

3. **Identity is not reachability.** All three checks pass on an element behind a
   sheet, in a hidden tab, or on another Space. Occlusion is a separate check
   with a separate code (§6.2).

4. **Value churn spends frames.** Including the value in the digest means a field
   the user is typing into invalidates the snapshot on every keystroke. That is
   intended — the state you observed is gone — but it makes `set_value` against a
   live-updating field unbindable. No mitigation is offered; the host re-observes.

5. **Identity says nothing about effect.** Whether the action did anything is
   `effect` / `verification` (§6.5), not this.

---

## 5. Observation

### `observe`

```json
{ "method": "observe",
  "params": {
    "session": "s-01J…",
    "target": { "kind": "window", "pid": 4711, "windowId": 90210 },
    "includeImage": true,
    "maxElements": 1500,
    "maxDepth": 64,
    "maxTextChars": 500
  } }
```

`target` is a **tagged union**, never a bag of optional fields:

```json
{ "kind": "app",    "app": "Notes" }
{ "kind": "window", "pid": 4711, "windowId": 90210 }
```

`{ "kind": "app" }` resolves to the app's frontmost usable window and is
ambiguous by design; `{ "kind": "window" }` is exact. Optional `app` *and*
optional `windowId` in one object is how a real-machine failure happened: the
contract said "app **or** window\_id" while the harness required both to match,
so a compliant model could not pass. A tagged union cannot express that
disagreement.

Omitted `maxElements` / `maxDepth` / `maxTextChars` mean the values in
`limits`. A value above the limit is `-32602`, not a silent clamp.

**Result**

```json
{
  "ok": true,
  "snapshot": {
    "snapshotId": "snap_4e2c9a…",
    "capturedAt": 1753574400123,
    "target": {
      "pid": 4711,
      "windowId": 90210,
      "bundleId": "com.apple.Notes",
      "appName": "Notes",
      "title": "Untitled",
      "bounds": { "x": 0, "y": 25, "width": 1200, "height": 800 },
      "layer": 0,
      "zIndex": 3,
      "displayId": "69732928"
    },
    "windowDigest": "sha256:1f0c…",
    "focusedElementToken": "el_9b41…",
    "selectedText": { "text": "abc", "truncated": false },
    "image": {
      "path": "/var/folders/…/maka-cu-images-8123/snap_4e2c9a.png",
      "format": "png",
      "widthPx": 2400,
      "heightPx": 1600,
      "byteLength": 743210,
      "sha256": "9d81…",
      "scale": 2.0
    },
    "displays": [
      { "displayId": "69732928",
        "logicalBounds": { "x": 0, "y": 0, "width": 1512, "height": 982 },
        "sourceBoundsPx": { "x": 0, "y": 0, "width": 3024, "height": 1964 },
        "scaleFactor": 2.0 }
    ],
    "obscuringRects": [ { "x": 300, "y": 100, "width": 400, "height": 300 } ],
    "elements": [ … ],
    "truncated": { "elements": false, "depth": false }
  }
}
```

`focusedElementToken` and `selectedText` are `null` when absent — both exist in
`AppSnapshot` already (`AccessibilitySnapshot.swift:111-113`) and are what
`type_text` needs to be verifiable.

`obscuringRects` lists the layer-0 windows stacked above the target, in screen
points. Presentation only: the Maka agent cursor uses it to decide how *high* to
draw, never whether to draw (`computer-use-types.ts:161-175`). The executor MUST
exclude the titleless full-screen Dock surface — the host currently filters it
out by hand (`cua-driver-backend.ts:1120-1135`), and that filter belongs where
the window list is read.

**Element**

```json
{
  "token": "el_7f3ab2…",
  "parentToken": "el_1b0c55…",
  "depth": 4,
  "role": "AXButton",
  "subrole": "AXCloseButton",
  "axIdentifier": "sendButton",
  "label": "Send",
  "value": null,
  "placeholder": null,
  "enabled": true,
  "focused": false,
  "selected": null,
  "frame": { "x": 1040, "y": 720, "width": 72, "height": 28 },
  "actions": ["press", "show_menu"],
  "digest": "sha256:c40f…",
  "truncated": []
}
```

- `parentToken` is `null` for the root. `null` and absent are the same on the
  wire; the executor SHOULD emit `null` for clarity.
- `actions` is a **closed set** of normalised names:
  `press`, `confirm`, `open`, `show_menu`, `raise`, `cancel`, `pick`,
  `increment`, `decrement`, `scroll_up`, `scroll_down`, `scroll_left`,
  `scroll_right`. The executor maps from raw AX action names; the host never
  sees `AXPress`. `secondary_action` (§6.1) takes one of these enums, which
  replaces `maka-cu`'s current free-form case-insensitive string matching
  (`ComputerUseService.swift:835-845`) and its "`X` is not a valid secondary
  action" class of error.
- `truncated` lists which of this element's text fields were cut at
  `maxTextChars`. An empty array is not omitted, so "was anything cut" is a
  field read, not a length comparison.

**Coordinate spaces, declared once.**

| field | space |
| --- | --- |
| `element.frame` | window-local logical points, origin at the window's top-left |
| `snapshot.target.bounds`, `obscuringRects`, `displays[].logicalBounds` | screen logical points |
| `image.widthPx` / `heightPx`, `displays[].sourceBoundsPx` | image pixels |

`image.scale` is `image.widthPx / target.bounds.width`, computed by the executor
from the image it actually captured — not from `NSScreen.backingScaleFactor`.
`screenshotPixelScale()` already does this division
(`ComputerUseService.swift:188-207`), and the host carries a comment that the
driver's own `scale_factor` is unreliable. Declaring the measured value removes
the host's derivation, and with it the class of bug where a click lands a quarter
of the way into a control.

The two frame conventions differ from what the host does today —
`cua-frame-state.ts:177-190` converts *screen*-coordinate element frames through
the window because the driver reports them in screen space. Under this protocol
`element.frame` is window-local, which is what `maka-cu` already computes
(`localFrame` / `windowRelativeFrame`), and that conversion block goes away.

**Truncation is never silent.** `truncated.elements` is `true` when the tree hit
`maxElements`, `truncated.depth` when it hit `maxDepth`. A truncated tree is
still a valid snapshot with valid tokens; the host decides whether to re-observe
with a higher bound.

### `window.list`

```json
{ "method": "window.list", "params": { "session": "s-01J…" } }
```

```json
{ "ok": true,
  "windows": [
    { "pid": 4711, "windowId": 90210, "appName": "Notes", "title": "Untitled",
      "bounds": { "x": 0, "y": 25, "width": 1200, "height": 800 },
      "layer": 0, "zIndex": 3, "onScreen": true, "displayId": "69732928" }
  ] }
```

Ordered front-to-back. `zIndex` is monotonically decreasing along the array; the
executor MUST NOT emit ties. The host uses this for occlusion decisions and for
resolving `{ "kind": "app" }` targets.

### `apps.list`

```json
{ "ok": true,
  "apps": [
    { "appId": "com.apple.Notes", "pid": 4711, "name": "Notes",
      "bundleId": "com.apple.Notes", "windowCount": 2, "running": true }
  ] }
```

Maps directly onto `CuAppSummary`. `appId` is the bundle id where one exists,
otherwise `pid:<n>` — the host's existing fallback
(`cua-driver-backend.ts:1170`), moved to the side that knows.

Note what is *not* here: `maka-cu`'s `listApps()` currently returns a rendered
text catalogue (`ComputerUseService.swift:420-426`). Rendered text is model-facing
prose. It goes.

### `permissions.check`

```json
{ "method": "permissions.check", "params": { "prompt": false } }
```

```json
{ "ok": true, "accessibility": true, "screenRecording": true,
  "screenRecordingProbe": "capture_succeeded" }
```

`screenRecordingProbe` ∈ `"capture_succeeded" | "capture_failed" | "not_probed"`.
The host currently prefers a live ScreenCaptureKit probe over the cached boolean
and has to guess which it got (`cua-driver-backend.ts:1898-1899`); this says.

`prompt: false` MUST NOT raise a TCC dialog. The host calls this at every
action start because a user can revoke at any time
(`computer-use-types.ts:192-194`), and a prompt there would be a dialog storm.

### `apps.launch`

```json
{ "method": "apps.launch",
  "params": { "session": "s-01J…", "app": "Notes", "waitForWindowMs": 8000 } }
```

```json
{ "ok": true,
  "pid": 4711, "bundleId": "com.apple.Notes", "name": "Notes",
  "foregroundTaken": false,
  "windows": [ { "windowId": 90210, "title": "Untitled" } ],
  "waited": { "ms": 3200, "reason": "window_appeared" }
}
```

- `foregroundTaken` is declared, not inferred. `CuLaunchedApp.focusHeld` is
  currently absent when the driver simply did not check
  (`computer-use-types.ts:64-68`) — an absent boolean that means "unknown" is a
  three-valued field pretending to be two.
- The executor MUST wait for a window rather than returning the empty array it
  sees at launch time. Measured: `launch_app` returns in 1.3–3.2 s and the window
  is mapped 2.3–4.5 s in, so the driver's `windows` array is empty on every real
  launch (`cua-driver-backend.ts:1704-1708`). `waited.reason` ∈
  `"window_appeared" | "timeout" | "not_requested"` says which happened.
- A launch that takes the foreground when `foregroundTaken` was meant to be false
  is still `ok: true` with `foregroundTaken: true`. It happened; hiding it does
  not un-happen it.

---

## 6. Dispatch

All dispatch methods share a request prefix:

```json
{ "session": "s-01J…", "snapshotId": "snap_4e2c9a…", "toolCallId": "call_…" }
```

`toolCallId` is opaque to the executor and echoed in the response. It is the only
concession to host bookkeeping and exists so a trace line can be joined to a tool
call without a side table.

### 6.1 `dispatch.element`

```json
{ "method": "dispatch.element",
  "params": {
    "session": "s-01J…",
    "snapshotId": "snap_4e2c9a…",
    "toolCallId": "call_1",
    "elementToken": "el_7f3ab2…",
    "expectElementDigest": "sha256:c40f…",
    "strictness": "element",
    "occlusionPolicy": "same_app",
    "action": { "kind": "click", "button": "left", "count": 1 },
    "observeAfter": { "includeImage": true, "settle": "quiesce" }
  } }
```

`action` is a tagged union:

```json
{ "kind": "click", "button": "left" | "right" | "middle", "count": 1 | 2 | 3 }
{ "kind": "set_value", "value": "hello" }
{ "kind": "select_text", "text": "hello" }
{ "kind": "secondary_action", "action": "show_menu" }
{ "kind": "scroll", "direction": "up" | "down" | "left" | "right", "pages": 1.0 }
```

`strictness` ∈ `"element" | "window"`:

- `"element"` (default) — E1–E3 on the target element only. An unrelated ticking
  label elsewhere in the window does not spend the frame.
- `"window"` — E1–E3 **and** `snapshot.windowDigest` must still match. The only
  defence against recycled row views (§4.4 item 1), at the cost of refusing on
  any change anywhere in the window.

`occlusionPolicy` ∈ `"same_app" | "any" | "none"`, default `"same_app"`:

- `"same_app"` — refuse only when another window **of the same pid** covers the
  element's centre. A semantic dispatch addresses an element, not a pixel, so a
  foreign window stacked above it has no bearing on whether `AXPress` reaches it.
  Treating foreign windows as occlusion made background operation impossible in
  the case that matters most: an app started by `apps.launch` begins at the
  bottom of the z-order, so every window on the user's screen sat above it and
  every semantic click was refused
  (`cua-driver-target-resolution.ts:238-250`). A same-app sheet is different and
  is still refused: the element underneath is not the thing to act on, whatever
  the AX tree says.
- `"any"` — refuse when any layer-0 window covers it.
- `"none"` — do not check.

`observeAfter.settle` ∈ `"none" | "quiesce"`. `"quiesce"` polls the AX tree
without an image until two consecutive window digests match, or
`limits.settleCeilingMs` elapses. The executor owns settling because it can watch
the tree without a round trip; the host currently does it with one
`get_window_state` call per poll.

**Result**

```json
{
  "ok": true,
  "toolCallId": "call_1",
  "outcome": "ok",
  "tier": "ax",
  "path": "ax_action",
  "effect": "confirmed",
  "verification": { "method": "tree_delta", "observedChange": true },
  "settle": { "waitedMs": 947, "quiesced": true, "reason": "quiesced" },
  "snapshot": { … a full snapshot, exactly as §5 … }
}
```

The snapshot returned here is `live` and supersedes the one that was quoted. One
round trip replaces the host's current dispatch → settle → observe sequence.

`snapshot` is present when `observeAfter` was requested and the capture
succeeded. When `observeAfter` was requested and the capture failed, the result
is still the dispatch outcome, with `snapshot: null` and
`postObservationError: { "code": "capture_failed", … }` — the action happened and
must be reported even though the frame after it could not be.

### 6.2 Element dispatch refusals

```json
{ "ok": false,
  "toolCallId": "call_1",
  "error": {
    "code": "element_changed",
    "message": "the element no longer matches the snapshot it was bound to",
    "detail": { "changed": ["value", "frame"] }
  } }
```

`detail.changed` is a subset of the closed set
`["role","subrole","axIdentifier","title","label","value","frame","actions","ancestors","siblingIndex"]`.
It exists so a host log can say *why* without parsing prose.

Codes, and what the host does with each:

| code | meaning | host response |
| --- | --- | --- |
| `snapshot_unknown` / `_spent` / `_superseded` / `_expired` / `_evicted` | §4.1 | re-observe |
| `element_unknown` | token is not in that snapshot | host bug; fail the turn |
| `element_released` | E1 failed — the AX reference is dead | re-observe (§4.4 item 2) |
| `element_changed` | E3 failed | re-observe |
| `process_replaced` | E2 failed — pid recycled | re-observe |
| `element_not_actionable` | resolves, but does not expose the requested action | tell the model |
| `element_disabled` | resolves and exposes it, but `enabled` is false | tell the model |
| `window_gone` | the target window no longer exists | re-observe |
| `window_changed` | window bounds or title changed | re-observe |
| `window_occluded` | per `occlusionPolicy` | re-observe |
| `permission_missing` | Accessibility or Screen Recording revoked mid-session | surface to the user |
| `screen_locked` | screen is locked | pause the session |
| `physical_input_active` | the user is typing or moving the mouse | wait, re-observe |
| `dispatch_refused` | attempted, the OS refused, nothing happened | tell the model |
| `outcome_unknown` | attempted, cannot tell whether it landed | spend the frame, re-observe |
| `aborted` | cancelled before dispatch | none |
| `not_implemented` | reserved method, this version | feature-detect |

### 6.3 `dispatch.point`

```json
{ "method": "dispatch.point",
  "params": {
    "session": "s-01J…",
    "snapshotId": "snap_4e2c9a…",
    "toolCallId": "call_2",
    "expectWindowDigest": "sha256:1f0c…",
    "point":      { "x": 640, "y": 400 },
    "startPoint": { "x": 100, "y": 100 },
    "space": "image_px",
    "occlusionPolicy": "any",
    "action": { "kind": "left_click", "count": 1 },
    "observeAfter": { "includeImage": true, "settle": "quiesce" }
  } }
```

- `space` is `"image_px"`. It is required and single-valued: a required field
  with one legal value is how a second space gets added later without either side
  guessing which one it was handed.
- `expectWindowDigest` is required. A point has no element to anchor to, so the
  whole window is the anchor — which is what the host already does for coordinate
  actions (`cua-driver-target-resolution.ts:336-365`).
- `occlusionPolicy` defaults to `"any"` here, not `"same_app"`. A pixel is a
  pixel: anything on top of it owns it.
- `startPoint` is present only for `drag`.

**Path selection is declared, not discovered.** `path` in the response is one of:

| `path` | mechanism | permitted when |
| --- | --- | --- |
| `ax_action` | `AXUIElementPerformAction` on the element under the point | always |
| `ax_attribute` | `AXUIElementSetAttributeValue` | always |
| `ax_select` | set `AXSelectedChildren` on the containing list | always |
| `cg_event_pid` | `CGEventPostToPid` — target-bound, no cursor warp | always |
| `skylight_pid` | `SLEventPostToPid` — background window path | always |
| `cg_event_global` | `CGEventPost` — **moves the system cursor** | only when `allowGlobalPointer: true` |
| `none` | nothing was dispatched | refusals |

When `allowGlobalPointer` is `false` and no permitted path can reach the target,
the executor MUST return `dispatch_refused` with
`detail: { "wouldRequirePath": "cg_event_global" }`. It MUST NOT fall back. This
is the invariant Maka refuses to trade: no cursor warp, no z-order change. The
current backend enforces it by refusing when no app window owns the click point
(`cua-driver-backend.ts:1954-1963`) — a check that only works because the host
knows which driver path a pid-bound click takes. Under this protocol the executor
states the path and the host verifies it: a response whose `path` was not
permitted is a protocol violation, and the host MUST treat the session as
compromised rather than accept the result.

`tier` and `path` are both declared, and their pairing is fixed:

| `tier` | permitted `path` |
| --- | --- |
| `ax` | `ax_action`, `ax_attribute`, `ax_select` |
| `semantic-background` | reserved for a future page-level path (`cdp`) |
| `coordinate-background` | `cg_event_pid`, `skylight_pid`, `cg_event_global` |

The host MUST reject an inconsistent pair as a protocol violation rather than
prefer one. `tier` uses Maka's exact vocabulary (`COMPUTER_USE_DISPATCH_TIERS`)
so `normalizeCuaDriverOutcome`'s `dispatchTier(path)` guess
(`cua-driver-result.ts:42-46`) — which maps every unrecognised path to
`coordinate-background`, including paths that do not exist yet — is deleted, not
ported.

### 6.4 `dispatch.key`

```json
{ "method": "dispatch.key",
  "params": {
    "session": "s-01J…",
    "snapshotId": "snap_4e2c9a…",
    "toolCallId": "call_3",
    "focusToken": "el_9b41…",
    "expectElementDigest": "sha256:aa10…",
    "action": { "kind": "type", "text": "hello" },
    "observeAfter": { "includeImage": false, "settle": "quiesce" }
  } }
```

```json
{ "kind": "type", "text": "hello" }
{ "kind": "key",  "key": "Return", "modifiers": ["command", "shift"] }
```

`modifiers` is a closed set: `command`, `shift`, `option`, `control`, `fn`.
`key` is a closed set of named keys plus single printable characters; the
executor rejects anything else with `-32602` rather than guessing. `maka-cu`'s
current key parsing goes through `KeyMapping.swift` from an xdotool-flavoured
string; the closed set replaces it on the wire, whatever the internal mapping
stays.

**`focusToken` is required and verified.** The executor MUST confirm that the
element currently focused in the target is the one named by `focusToken`, with a
matching digest, before posting any key event. `maka-cu` today types into
`snapshot.focusedElement` whatever that has become since the snapshot
(`ComputerUseService.swift:1366-1385`) — which is the same class of defect as
re-resolving an index. Focus mismatch is `focus_changed`, and it maps to
`target_changed`.

Key events are posted to the target pid. The executor MUST NOT activate the
application, raise its window, or change the frontmost app.

### 6.5 Outcome, path, effect — the fields that used to be inferred

Four required fields on every dispatch result, all closed sets, none optional:

| field | values |
| --- | --- |
| `outcome` | `ok`, `refused`, `failed`, `unknown` |
| `tier` | `ax`, `semantic-background`, `coordinate-background` |
| `path` | table in §6.3 |
| `effect` | `confirmed`, `unverifiable`, `suspected_noop` |

Plus `verification`, which is what makes `effect` readable:

```json
"verification": { "method": "value_readback", "observedChange": true }
```

`method` ∈ `"none" | "action_result" | "value_readback" | "selection_readback" |
"focus_readback" | "tree_delta"`.

This is the distinction the current shape cannot express: `effect: unverifiable`
with `method: "none"` means *never checked*; `effect: unverifiable` with
`method: "value_readback"` means *checked and inconclusive*. Today both collapse
to one enum, and the host cannot tell a driver that does not verify from a driver
that verified and could not confirm.

Rules the executor MUST follow:

- A bare `AXUIElementPerformAction` returning `.success` is **not** confirmation.
  It yields `effect: "unverifiable"`, `verification.method: "action_result"`.
  `AXPress` succeeding means the message was accepted, not that anything moved.
- `set_value` MUST read the value back. Equal to the requested value →
  `confirmed` / `value_readback`. Equal to the *previous* value →
  `suspected_noop`. Anything else → `unverifiable`.
- `select_text` MUST read `AXSelectedText` back → `selection_readback`.
- `click` with `observeAfter.settle: "quiesce"` MAY report `confirmed` /
  `tree_delta` when the post-action window digest differs from the pre-action
  one. With `settle: "none"` it MUST NOT: no time was given for a change to
  appear, so absence of change is not evidence.
- `secondary_action` gets `action_result` only. There is nothing generic to read
  back.

`verified` is **not** a wire field. The host sets
`verified = (effect === "confirmed")` when building `CuDispatchOutcome`. Two
fields carrying one bit is how `verification()` in `cua-driver-result.ts:48-58`
ended up deriving each from the other with three fallbacks.

### 6.6 `screen.capture`

```json
{ "method": "screen.capture",
  "params": { "session": "s-01J…", "displayId": "69732928" } }
```

```json
{ "ok": true,
  "image": { "path": "…/cap_8812.png", "format": "png",
             "widthPx": 3024, "heightPx": 1964, "byteLength": 2_100_331,
             "sha256": "…", "scale": 2.0 },
  "displayId": "69732928",
  "capturedAt": 1753574400123 }
```

Whole-display capture, no snapshot, no binding, no state change. It exists
because `CuAction` has a `screenshot` member and the model may ask for one
without a target.

---

## 7. Errors, mapping and bounds

### 7.1 Domain code → Maka error code

The host maps mechanically. No inference, no message matching.

| executor `code` | `ComputerUseErrorCode` |
| --- | --- |
| `snapshot_unknown`, `snapshot_expired`, `snapshot_evicted`, `element_unknown` | `stale_frame` |
| `snapshot_spent` | `duplicate_action` |
| `snapshot_superseded` | `stale_epoch` |
| `element_released`, `window_gone`, `process_replaced`, `app_not_found` | `target_missing` |
| `element_changed`, `window_changed`, `focus_changed` | `target_changed` |
| `window_occluded` | `target_occluded` |
| `element_not_actionable`, `element_disabled`, `unsupported_action`, `not_implemented` | `unsupported_action` |
| `permission_missing` | `permission_missing` |
| `screen_locked` | `screen_locked` |
| `physical_input_active` | `user_intervened` |
| `invalid_point` | `invalid_coordinate` |
| `capture_failed`, `response_too_large`, `image_write_failed` | `capture_failed` |
| `outcome_unknown` | `outcome_unknown` |
| `aborted` | `aborted` |
| `timeout` | `timeout` |
| `dispatch_refused` | **see open questions** |

`COMPUTER_USE_ERROR_CODES` has no member meaning *"the executor attempted the
action and the OS refused it, and nothing happened"*. Today that collapses into
`capture_failed` via `normalizeCuaDriverOutcome`'s default branch, which tells
the model a screenshot failed when a button refused a press.

### 7.2 Cancellation

```json
{ "jsonrpc": "2.0", "method": "$/cancel", "params": { "id": 42 } }
```

A notification. The executor:

- answers request 42 with `aborted` if it has not yet dispatched;
- **ignores** the cancel if it has already dispatched, and answers with whatever
  actually happened.

An action already in flight cannot be un-fired, and reporting `aborted` for one
that landed is a lie the host would act on. The host already distinguishes these
by request stage (`cua-driver-service.ts:538-552`); this makes the executor
agree instead of the host inferring from where the kill landed.

`capture.next` long polls MUST be cancellable this way, or a poll outstanding at
session end pins the process.

### 7.3 Timeouts

The executor has no timeout of its own except `limits.settleCeilingMs`. The host
owns request deadlines (`DEFAULT_REQUEST_TIMEOUT_MS = 20_000`) and enforces them
by `$/cancel` followed, if the request had already been delivered, by teardown.

### 7.4 Bounds

Everything bounded says so on the wire:

| bound | field that reports it |
| --- | --- |
| element count | `snapshot.truncated.elements` |
| tree depth | `snapshot.truncated.depth` |
| element text | `element.truncated: ["value", …]` |
| selected text | `snapshot.selectedText.truncated` |
| settle time | `settle.reason: "ceiling"` |
| launch wait | `waited.reason: "timeout"` |
| capture stream frames | `capture.next` → `dropped: n` |

### 7.5 Response size

If a response would exceed `limits.maxResponseBytes`, the executor MUST reduce
`maxElements` by half and retry, up to three times, and report the reduction in
`truncated.elements`. If it still does not fit, it returns
`response_too_large` with `detail: { "bytes": n, "limit": m }`. It MUST NOT drop
fields to fit.

---

## 8. References, not payloads

**Every image is a file path. There is no size threshold and no inline branch.**

A threshold means two code paths, and the host would have to implement both
forever to handle the small case. Base64 on a line-delimited channel is a 4/3
blow-up that stalls every other pending response while one 8 MB line is written —
today the host raises `MAX_STDOUT_BUFFER` to 32 MiB to survive it
(`cua-driver-service.ts:23`). At the frame rates a live mirror needs, inlining is
not merely wasteful, it is impossible.

Everything else stays inline. The AX tree is bounded by `maxElements` and
`maxTextChars` and is declared-truncating, so it cannot surprise the channel.

**The line: images by reference, structured data inline, one message capped at
`limits.maxResponseBytes` (1 MiB).**

Image file contract:

- The executor writes into `imageDir` and nowhere else.
- Filenames are executor-chosen and opaque. The host addresses them only by the
  `path` it was given.
- `sha256` and `byteLength` are of the file's bytes as written. The host MAY
  verify; a mismatch is a protocol violation.
- **Lifetime is the snapshot's lifetime.** The executor deletes an image when its
  snapshot leaves the live set — spent, superseded, expired or evicted. The host
  must copy or consume before then; `limits.snapshotTtlMs` is therefore also the
  file's guaranteed lifetime, and it is in the handshake so the host does not
  hardcode it.
- `screen.capture` images are not attached to a snapshot. They live for
  `limits.snapshotTtlMs` from `capturedAt` and are then deleted.
- If writing would push `imageDir` past `limits.imageDirBudgetBytes`, the
  executor evicts its oldest own files first; if it still does not fit it returns
  `image_write_failed`. It never silently returns a snapshot without the image
  the caller asked for.
- After an executor crash the files leak. The host owns `imageDir` and MUST purge
  it before every spawn.

---

## 9. Concurrency

The executor uses one reader and a set of serial lanes:

| lane | methods |
| --- | --- |
| `control` | `host.hello`, `session.*`, `permissions.check`, `apps.list`, `window.list` |
| `target:<pid>:<windowId>` | `observe`, `dispatch.*` for that target |
| `capture:<streamId>` | `capture.next` for that stream |
| `misc` | `apps.launch`, `screen.capture` |

Within a lane, strict FIFO. Across lanes, concurrent. Two consequences the host
depends on:

- All observes and dispatches against one window are ordered, so a dispatch can
  never overtake the observe that produced its snapshot.
- A `capture.next` long poll cannot block a dispatch. This is the framing
  property that has to exist **now** for the stream to land later without a
  protocol break.

The host serialises per session today (`withOperationQueue`); per-target is
finer and remains safe because the host's queue is still upstream of it.

---

## 10. Capture stream (reserved, not implemented in v1)

Maka's picture-in-picture mirror repaints from the screenshot each action
returns. A live mirror needs a stream, and this channel is request/response —
so the stream is long-polling, the way Codex does it on its privileged channel
(`AppStartCapture` then repeated `AppNextCaptureUpdate`).

The method space is reserved now. In `maka.cu/1` all three return
`{ "ok": false, "error": { "code": "not_implemented" } }` — a **domain** result,
not `-32601`, so feature detection is a stable field read and the names can never
be taken by something else.

```json
{ "method": "capture.start",
  "params": { "session": "s-01J…",
              "target": { "kind": "window", "pid": 4711, "windowId": 90210 },
              "maxFps": 10, "format": "jpeg" } }
→ { "ok": true, "streamId": "st_…", "ringFrames": 30, "ttlMs": 30000 }

{ "method": "capture.next",
  "params": { "streamId": "st_…", "sinceSeq": 41, "timeoutMs": 5000 } }
→ { "ok": true, "seq": 44, "dropped": 2,
    "frames": [ { "seq": 43, "capturedAt": 1753574400500, "image": { "path": …, "sha256": … } },
                { "seq": 44, "capturedAt": 1753574400600, "image": { … } } ] }
→ { "ok": true, "seq": 41, "dropped": 0, "frames": [], "timedOut": true }

{ "method": "capture.stop", "params": { "streamId": "st_…" } }
→ { "ok": true, "released": { "frames": 30 } }
```

What v1 already provides so this needs no protocol change:

- **Images are already references.** A 10 fps stream is path churn, not stdout
  churn.
- **The `capture` lane already exists** (§9), so a 5 s poll does not block a
  dispatch.
- **`$/cancel` already applies** to a long poll (§7.2), so a session ending with
  a poll outstanding does not pin the process.
- **`dropped` is a declared field**, so a slow host loses frames visibly.
- **`ringFrames` and `ttlMs` come back from `capture.start`**, so the host never
  hardcodes the ring size.

What a future version must add and is deliberately absent now: nothing in the
framing, the handshake, or the error space. `capabilities.captureStream` flips to
`true` and the three methods start answering. That is the whole delta.

---

## 11. Process lifecycle

**Start.** The host spawns the executor as a **direct child**. macOS attributes
TCC grants through the responsibility chain, and a helper launched via
`open`/LaunchServices gets its own attribution and its own prompts. The host
purges `imageDir`, spawns, sends `host.hello`, and treats any failure before a
successful `session.begin` as a start failure.

**Death.** The host classifies in-flight requests by stage — already implemented
in `cua-driver-service.ts:423-468`:

| stage at death | host result |
| --- | --- |
| queued, never written to stdin | `service_unavailable` |
| written or delivered | `outcome_unknown` |

The executor's obligations that make this sound:

- exactly one response per request id;
- flush stdout before exiting on a handled signal;
- snapshot ids carry a per-process nonce, so nothing from a previous generation
  can be mistaken for live state (§4.1).

**SIGTERM.** Stop reading new requests; answer queued-but-unstarted with
`aborted`; let in-flight mutating dispatches finish within
`limits.shutdownGraceMs`; end every session (which removes cursors and deletes
images); exit 0. The host SIGKILLs after the grace period.

**Crash.** Images leak; the host purges `imageDir` at next start. Every snapshot
id from the dead generation fails `snapshot_unknown`, never silently resolves.

**Host death.** The `hostPid` poll (§2) exits the executor within 2 s. Without
it, an executor holding Accessibility outlives every host crash.

---

## 12. Conformance vectors

Each rule below needs a test that fails without it. Executor tests are Swift
(`OpenComputerUseKitTests`), host tests are the `@maka/computer-use` backend
suite; the fixture rows are shared JSON so both ends assert the same bytes.

Frame binding:

1. Dispatch quoting a spent snapshot → `snapshot_spent`, and the action is not
   performed.
2. Dispatch quoting a snapshot superseded by a later `observe` of the same window
   → `snapshot_superseded`; a snapshot of a *different* window stays live.
3. Dispatch after `limits.snapshotTtlMs` → `snapshot_expired`.
4. `snapshotsPerSession + 1` observes → the oldest yields `snapshot_evicted`, not
   `snapshot_unknown`.
5. Token whose element was destroyed → `element_released`; token whose element
   had its label changed → `element_changed` with `detail.changed: ["label"]`.
6. `expectElementDigest` from snapshot A used against a token from snapshot B →
   `element_unknown` (tokens are snapshot-scoped) — not a successful dispatch.
7. `strictness: "window"` refuses when an unrelated element in the window
   changed; `strictness: "element"` does not.
8. A refused dispatch leaves the snapshot `live`; an `outcome_unknown` spends it.
9. Snapshot ids from two executor generations never collide.

Declared schema:

10. Every dispatch result carries all four of `outcome`, `tier`, `path`,
    `effect`; a response missing any is rejected by the host as a protocol
    violation.
11. `tier`/`path` pairs outside the §6.3 table are rejected, not coerced.
12. `set_value` whose readback equals the previous value reports
    `suspected_noop`, not `ok`.
13. `click` with `settle: "none"` never reports `effect: "confirmed"` via
    `tree_delta`.
14. With `allowGlobalPointer: false`, a target reachable only by
    `cg_event_global` yields `dispatch_refused` with
    `wouldRequirePath: "cg_event_global"` — and the system cursor does not move.

Versioning:

15. `host.hello` with an unknown protocol string → `-32000` with `supported`,
    exit 78, host does not retry.
16. Any method before `host.hello` → `-32001`.

Bounds and references:

17. A tree over `maxElements` sets `truncated.elements: true` and still returns
    usable tokens.
18. An element value over `maxTextChars` sets `element.truncated: ["value"]`, and
    its digest is over the untruncated string (edit past char 500 → digest
    changes → `element_changed`).
19. No response contains a base64 image.
20. An image file is deleted when its snapshot is superseded, and the host's read
    of a stale path fails rather than returning a previous frame's pixels.

Lifecycle:

21. `session.end` releases every snapshot and image and removes any cursor;
    `released` counts match.
22. `capture.start`/`next`/`stop` all return `not_implemented` as a domain result
    with `ok: false`, never `-32601`.
23. `$/cancel` before dispatch yields `aborted`; after dispatch it is ignored and
    the real outcome is reported.
24. Killing the executor mid-dispatch produces `outcome_unknown` on the host, and
    `service_unavailable` for requests never written.

---

## 13. Deliberate exclusions

- **No tool schemas, no descriptions, no instructions.** `ToolDefinitions.swift`
  and `computerUseServerInstructions` do not survive. Maka's runtime owns every
  model-facing word, and a second copy in the executor is a second copy to drift.
- **No rendered text.** `AppSnapshot.renderedText`, the tab-indented tree, the
  `list_apps` catalogue: all of it is model-facing prose generated from data the
  host now receives as data.
- **No approval logic.** Approval classes are runtime policy
  (`COMPUTER_USE_APPROVAL_CLASSES`); the executor neither knows nor asks.
- **No redaction.** The executor does not put application content anywhere except
  the declared observation fields (§1.2), so there is nothing to redact.
- **No retries.** The executor performs an action once. Retry is a host decision
  because only the host knows whether the model has been told.
- **No `verified` field.** One bit, two producers, three fallbacks; see §6.5.
- **No env-var behaviour switches.** `maka-cu` currently reads
  `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS` and
  `OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS` from the process environment. Every
  behavioural switch this protocol needs is a handshake parameter, so the wire
  says what the executor will do rather than the ambient environment.
