# maka-cu Host Protocol (`maka.cu/2`)

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

### Why this is version 2

`maka.cu/1` was built twice from this document, once in Swift and once in
TypeScript, by engineers who could not talk to each other. The two ends did not
interoperate, and six of the disagreements were holes in this text rather than
bugs in either implementation: a refusal could not carry the fields §6.5 made
mandatory (§6.5), hashes were written two ways in one document (§1.3), the key
surface could not express what the caller actually holds (§6.4), apps were named
in two namespaces (§5.1), one error code covered two situations (§6.2), and
`element.frame` had one declared space and a different one in practice (§5.3).

Each is closed below, and each closure names the defect that produced it. Five of
them move the wire, so the version string moves with them: a `maka.cu/1` peer is
not compatible and must fail the handshake rather than degrade (§2). There is no
`maka.cu/1` peer worth interoperating with — no two of them agreed.

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
- Maximum encoded message size is `limits.maxResponseBytes` (§2). A response that
  would exceed it MUST NOT be truncated silently — see §7.5.
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

**The `ok: false` arm of a dispatch result carries the declared dispatch fields
too.** `dispatch.element`, `dispatch.point` and `dispatch.key` answer with

```json
{ "ok": false, "toolCallId": "call_1",
  "outcome": "refused", "tier": "ax", "path": "none",
  "effect": "unverifiable",
  "verification": { "method": "none", "observedChange": false },
  "error": { "code": "…", "message": "…", "detail": { } } }
```

on both arms. `outcome`, `tier`, `path` and `effect` are required on the refusal
arm exactly as they are on the success arm. In `maka.cu/1`
this arm was `error` and nothing else, which put §6.5 ("four required fields on
every dispatch result") in direct contradiction with §1.1, and the two
implementations resolved it in opposite directions: the Swift executor's
`refused()` computed `path` and `tier` and then dropped them on the floor at
`emit(id:failure:)`, while the TypeScript host treated an `ok: true` result whose
`outcome` was not `ok` as a protocol violation and SIGKILLed the child. Both were
reading this document correctly. A refusal is an outcome the model must read, and
§6.3 already assigns it `path: none`, so it was always meant to be expressible.

No other method's `ok: false` arm carries these fields. `observe` refusing with
`capture_failed` dispatched nothing, so an `outcome` on it would be a field with
no producer.

### 1.2 No application text outside declared observation fields

`error.message` is a fixed sentence chosen by `error.code`. `error.detail`
contains enums and numbers only. The only fields in this protocol that may carry
text belonging to the observed application are `element.label`,
`element.value`, `element.placeholder`, `element.axIdentifier`,
`snapshot.target.title`, `snapshot.selectedText.text`, and the display names
`appName` / `apps.list[].name` — all of which the host already treats as
untrusted content, and none of which is ever used as a key (§5.1).

This is a change of posture. The current backend carries a comment that
`cua-driver does NOT redact secrets — the runtime redacts every backend-supplied
message upstream` (`cua-driver-backend.ts:15-16`). Under this protocol the
executor never puts application content in a diagnostic string, so there is no
message-redaction pass to get wrong.

### 1.3 One way to write a hash

Every hash on this wire is the string `"<algorithm>:<lowercase hex>"`. In
`maka.cu/2` the algorithm is always `sha256`, so every hash begins `sha256:`.

This applies without exception to `element.digest`, `snapshot.windowDigest`,
`image.sha256` — including the images in `screen.capture` (§6.6) and in the
reserved capture stream (§10). The field name `image.sha256` is kept: it declares
which algorithm the prefix is required to state, and renaming it would break the
wire to buy nothing.

Bare hex is not accepted anywhere. A host comparing hashes computes its own
digest and prefixes it before comparing; it MUST NOT strip a prefix, MUST NOT
accept both forms, and MUST NOT compare only the tail. A bare-hex value from the
executor is a protocol violation like any other undeclared shape (§8).

The rule exists because `maka.cu/1` wrote both forms in one document — bare hex
in §5, §6.6 and §8, `"sha256:c40f…"` in §4.3 and the element example — and both
implementations were consistent with the half they read. `maka-cu` emits the
prefixed form everywhere (`HostDigest.sha256` prefixes; `HostImageStore` uses it
for image bytes too), while the host verified an image with
`createHash('sha256').update(bytes).digest('hex')` and compared for exact
equality. Every screenshot therefore mismatched, and the host's response to a
mismatch is to declare the session compromised and kill the executor. The
executor is already correct; the host is the side that changes.

---

## 2. Handshake

`host.hello` MUST be the first message on the connection. Anything else gets
`-32001`.

**Request**

```json
{
  "jsonrpc": "2.0", "id": 1, "method": "host.hello",
  "params": {
    "protocol": "maka.cu/2",
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
  "protocol": "maka.cu/2",
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
             "data": { "supported": ["maka.cu/2"] } } }
```

then flush stdout and exit with status `78` (`EX_CONFIG`). The host MUST classify
this as `service_mismatch` and MUST NOT retry — `CuaDriverService.startWithBudget`
already treats `service_mismatch` as non-retryable
(`cua-driver-service.ts:200-203`). Silent degradation to a subset is forbidden in
both directions.

`supported` lists `maka.cu/2` and nothing else. `maka.cu/1` is withdrawn, not
deprecated: the parts of it that moved are exactly the parts the two `maka.cu/1`
implementations disagreed about, so a peer still speaking it is a peer whose
behaviour on those points is unknown. Accepting it back would reintroduce every
split this version closes.

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

The digest is exposed to the host as `element.digest` — written the one way §1.3
declares, like every other hash here — and the host MUST echo it in every element
dispatch (§6.1). Echoing is not redundant with the executor's own record: it
catches a host that has mixed up two elements from two snapshots, which the
executor's record by construction cannot. When the echo does not match, the
executor answers `element_digest_mismatch`, which is a different diagnosis from
both `element_unknown` and `element_changed` — see §6.2.

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
   the hard one — but the invalidation rate has not been measured. See §14.

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

### 5.1 One namespace for naming an app

There is exactly one string that names an app on this wire, and it is called
`appId`.

- `appId` is the bundle identifier when the process has one, otherwise
  `pid:<n>`. That is the host's existing fallback (`cua-driver-backend.ts:1170`),
  moved to the side that knows.
- `apps.list`, `window.list`, `snapshot.target` and the `apps.launch` result all
  carry it, spelled the same way, for the same process.
- `{ "kind": "app", "app": … }` (§5.2) takes an `appId` and nothing else. The
  executor resolves it by exact string match against `appId`. It MUST NOT match
  against `appName`, against `snapshot.target.title`, or against any prefix or
  case-folded form of either.
- `appName` is a display string. It is untrusted application content (§1.2), it
  is localised, two apps may share one, and it is never a key.
- There is no `bundleId` field anywhere on this wire. It was a second spelling of
  the same fact, and a second spelling is what this section exists to remove; a
  caller that wants to know whether the process has a bundle id reads whether
  `appId` starts with `pid:`. The host MUST NOT hand the model two app identifier
  strings, because then the model has to guess which one to echo back.

The single exception is `apps.launch`'s **request** `app`, which may be a bundle
id or a human name, because an app that is not running has never appeared in
`apps.list` and so has no `appId` the caller could have learned. The executor
resolves it through LaunchServices and returns the resolved `appId`; every later
call uses that. This is what deletes the host's `isBundleId` regex sniff
(`cua-driver-backend.ts:1676-1682`), which guessed a namespace from the shape of
a string.

**Why the rule is stated this baldly.** In `maka.cu/1` `apps.list` returned
bundle ids, `window.list` carried only `appName`, and nothing said which of the
two a caller's `app` string was. The host built its `appId` as
`bundleId ?? appName ?? pid:<n>` and then resolved a caller's `app` against
`window.list`'s `appName` and `title` — so for every app that has a bundle id,
the string the host handed out could never match the strings it matched against,
and every `{app, windowId}` observation of such an app was refused. A reviewer
reproduced it on the first try. `cua-driver` never had this bug because it used
one namespace, the app *name*, in both places (`appIdForWindow` feeds both the
`apps.list` key and the window match). One namespace is the fix; bundle id is the
better one to standardise on, because a display name is neither unique nor stable
across locales.

Which side changes: both. The executor adds `appId` to `window.list` and
`snapshot.target` and resolves `{kind: "app"}` on it. The host stops matching on
`appName`/`title` and passes `appId` through unaltered.

When the host is given both an app string and a window id, it resolves the window
id — exact, numeric — and then requires that window's `appId` to equal the app
string. Disagreement is `target_missing`, because no window satisfies the pair;
honouring one input and discarding the other would be acting on a target the
caller did not name. This is not the old over-strict rule, which required both to
match when the caller had sent only one (§5.2).

### 5.2 `observe`

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
{ "kind": "app",    "app": "com.apple.Notes" }
{ "kind": "window", "pid": 4711, "windowId": 90210 }
```

`app` is an `appId` (§5.1). `{ "kind": "app" }` resolves to the app's frontmost
usable window and is ambiguous by design; `{ "kind": "window" }` is exact.
Optional `app` *and* optional `windowId` in one object is how a real-machine
failure happened: the contract said "app **or** window\_id" while the harness
required both to match, so a compliant model could not pass. A tagged union
cannot express that disagreement.

The **executor** resolves `{ "kind": "app" }`. It owns the window inventory and
the z-order, and the host that tried to pre-resolve an app string against
`window.list` is the host that invented title matching to make it work (§5.1).

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
      "appId": "com.apple.Notes",
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
      "sha256": "sha256:9d81…",
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

**Truncation is never silent.** `truncated.elements` is `true` when the tree hit
`maxElements`, `truncated.depth` when it hit `maxDepth`. A truncated tree is
still a valid snapshot with valid tokens; the host decides whether to re-observe
with a higher bound.

### 5.3 Coordinate spaces, declared once

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
of the way into a control. Measuring it is only half of the guarantee: the
bitmap it is measured against must be drawn edge to edge, and §6.7 says why that
is a rule and not an obvious consequence.

**`element.frame` stays window-local, and the host converts it exactly once.**
The wire is window-local because that is what `maka-cu` already computes
(`localFrame` / `windowRelativeFrame`) and because a window-local rectangle stays
correct when the window moves between observe and read.

The field it lands in on the host, `CuObservedElement.frame`, is **screen**
logical points, for every backend. `validateSemanticElementVisibility` compares
its centre against `window.bounds` and feeds it to `topWindowAtPoint`, both in
screen space; `bindCuaSemanticActionToObservation` subtracts the window origin
from it (`cua-frame-state.ts:171-190`); and the same rectangle is printed to the
model beside `snapshot.target.bounds`, which is screen space. Two spaces in one
field, chosen by whichever backend filled it, is the defect: the `cua-driver`
backend passes screen frames straight through, and a host that also passes
`maka.cu` window-local frames straight through makes every consumer wrong by the
window's origin — an agent cursor drawn at the wrong place, and an occlusion
check that refuses a visible control.

So: the conversion is `screen = element.frame + snapshot.target.bounds.origin`,
and it happens in the one function that turns a `snapshot` into a
`CuObservation`, where both values are in hand. Nowhere else.

**How the host knows which space it is holding: from the type, never from the
call site.** A rectangle inside the protocol's own element type is window-local;
a rectangle inside `CuObservedElement` is screen. No function may hold one and
treat it as the other, and the conversion function is the only place both types
appear. A comment claiming a space is not a mechanism — the `elementFrame`
parameter in `cua-frame-state.ts` is documented as "window-local screenshot
pixels" eight lines above the code that treats it as screen points, and both
statements shipped.

### 5.4 `window.list`

```json
{ "method": "window.list", "params": { "session": "s-01J…" } }
```

```json
{ "ok": true,
  "windows": [
    { "pid": 4711, "windowId": 90210, "appId": "com.apple.Notes",
      "appName": "Notes", "title": "Untitled",
      "bounds": { "x": 0, "y": 25, "width": 1200, "height": 800 },
      "layer": 0, "zIndex": 3, "onScreen": true, "displayId": "69732928" }
  ] }
```

Ordered front-to-back. `zIndex` is monotonically decreasing along the array; the
executor MUST NOT emit ties. `appId` is required and is the same namespace
`apps.list` returns (§5.1); its absence here is what made an app string
unresolvable against this list. The host uses this list for occlusion decisions
and for joining a window id to its pid — not for resolving `{ "kind": "app" }`,
which the executor does (§5.2).

### 5.5 `apps.list`

```json
{ "ok": true,
  "apps": [
    { "appId": "com.apple.Notes", "pid": 4711, "name": "Notes",
      "windowCount": 2, "running": true }
  ] }
```

Maps directly onto `CuAppSummary`. `appId` is defined once in §5.1; `name` is the
display string and is never matched against.

Note what is *not* here: `maka-cu`'s `listApps()` currently returns a rendered
text catalogue (`ComputerUseService.swift:420-426`). Rendered text is model-facing
prose. It goes.

The list is what is running **now**, not what was running when the executor
started. This is stated because it is not free on macOS: the obvious source,
`NSWorkspace.shared.runningApplications`, is a cache AppKit refreshes out of
notifications, and in a process whose main thread never runs a run loop that
refresh never lands on any other thread — which is every thread that answers a
request, since the reader parks the main one in `readLine`. Measured before it
was fixed: 91 applications at executor start, TextEdit started externally and
confirmed with `pgrep`, 91 applications and no TextEdit for the rest of the
process's life. The same freeze applies to the frontmost application, which stays
at whoever held the foreground when the executor launched.

An executor that answers from that cache is not merely out of date. It cannot
resolve an app it launched itself: `apps.launch` starts the process, the process
registers — measured at 4990 ms — and the poll searches a list that will never
contain it, so the call spends the caller's whole budget and answers `timeout`
for an app that is on screen. Read the running set from the kernel and the
frontmost pid from the window server, once per request.

### 5.6 `permissions.check`

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

### 5.7 `apps.launch`

```json
{ "method": "apps.launch",
  "params": { "session": "s-01J…", "app": "Notes", "waitForWindowMs": 8000 } }
```

```json
{ "ok": true,
  "pid": 4711, "appId": "com.apple.Notes", "name": "Notes",
  "foregroundTaken": false,
  "windows": [ { "windowId": 90210, "title": "Untitled" } ],
  "waited": { "ms": 3200, "reason": "window_appeared" }
}
```

- `params.app` is the one place a display name is legal (§5.1), because an app
  that is not running has no `appId` the caller could have learned. The result's
  `appId` is the resolved one, and every later call uses that.
- `foregroundTaken` is declared, not inferred. `CuLaunchedApp.focusHeld` is
  currently absent when the driver simply did not check
  (`computer-use-types.ts:64-68`) — an absent boolean that means "unknown" is a
  three-valued field pretending to be two. It is a difference between two reads,
  one before the launch and one after, and both must be live (§5.5): answering
  both from a value cached at executor start makes the field a constant `false`,
  so an executor that did take the user's foreground reports that it did not.
- The executor MUST wait for a window rather than returning the empty array it
  sees at launch time. Measured: `launch_app` returns in 1.3–3.2 s and the window
  is mapped 2.3–4.5 s in, so the driver's `windows` array is empty on every real
  launch (`cua-driver-backend.ts:1704-1708`). `waited.reason` ∈
  `"window_appeared" | "timeout" | "not_requested"` says which happened.
- `waitForWindowMs` is a budget for the whole of "make this app usable", not just
  for the window wait at the end of it. The executor spends it on both phases in
  order: starting the application and waiting for the process to register, then
  waiting for a window. An executor that resolves the app against a clock of its
  own and applies the caller's budget only to the second phase refuses launches
  the caller had allowed time for — measured: a cold TextEdit on a loaded machine
  took 5571 ms to register, against a hardcoded five-second resolve and a
  declared budget of 8000 ms. With no `waitForWindowMs` the executor uses its own
  default, and `waited.reason` is `not_requested`.
- A cold launch that outlives the budget is `timeout`, never `app_not_found`.
  They are different facts and the caller acts on them differently:
  `app_not_found` means nothing on this machine answers to that name, and the
  model's move is to name something else; `timeout` means the application exists,
  was started, and had not registered in time, and the model's move is to wait or
  observe again. Answering `app_not_found` for a slow launch is a lie the model
  acts on — it goes off looking for other spellings of an app that is already
  starting, and the launch that did happen is invisible to it.
- An application the executor will not drive at all — the safety list, currently
  password managers — is `unsupported_action`, not `app_not_found` and not
  `permission_missing`. It is present, no macOS grant changes the answer, and
  another spelling of the name will not either.
- A launch the system itself refuses is `dispatch_refused`: it was attempted and
  did not happen. The app is not missing.
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
  "outcome": "refused",
  "tier": "ax",
  "path": "none",
  "effect": "unverifiable",
  "verification": { "method": "none", "observedChange": false },
  "error": {
    "code": "element_changed",
    "message": "the element no longer matches the snapshot it was bound to",
    "detail": { "changed": ["value", "frame"] }
  } }
```

The four declared fields are here for the reason §1.1 gives: a refusal is an
outcome, and §6.5 requires them on every dispatch result, this arm included.

`detail.changed` is a subset of the closed set
`["role","subrole","axIdentifier","title","label","value","frame","actions","ancestors","siblingIndex"]`.
It exists so a host log can say *why* without parsing prose.

Codes, and what the host does with each:

| code | meaning | host response |
| --- | --- | --- |
| `snapshot_unknown` / `_spent` / `_superseded` / `_expired` / `_evicted` | §4.1 | re-observe |
| `element_unknown` | the token is not in that snapshot at all | host bug; fail the turn |
| `element_digest_mismatch` | the token is in that snapshot, but `expectElementDigest` is not the digest the snapshot recorded for it | host bug; discard the frame and re-observe, never re-send against it |
| `element_released` | E1 failed — the AX reference is dead | re-observe (§4.4 item 2) |
| `element_changed` | E3 failed — the element's *current* digest differs from the recorded one | re-observe |
| `process_replaced` | E2 failed — pid recycled | re-observe |
| `element_not_actionable` | resolves, but does not expose the requested action | tell the model |
| `element_disabled` | resolves and exposes it, but `enabled` is false | tell the model |
| `window_gone` | the target window no longer exists | re-observe |
| `window_changed` | window bounds or title changed | re-observe |
| `window_occluded` | per `occlusionPolicy` | re-observe |
| `permission_missing` | Accessibility or Screen Recording revoked mid-session | surface to the user |
| `screen_locked` | screen is locked | pause the session |
| `physical_input_active` | the user is typing or moving the mouse | wait, re-observe |
| `dispatch_refused` | attempted, the OS refused, nothing happened — or nothing was attempted because every path that could reach the target was forbidden (§6.3) | tell the model |
| `outcome_unknown` | attempted, cannot tell whether it landed | spend the frame, re-observe |
| `aborted` | cancelled before dispatch | none |
| `not_implemented` | reserved method, this version | feature-detect |

**Three situations, three codes, and why the third one is new.** The echoed
digest (§4.3) exists to catch a host that mixed up two elements from two
snapshots. `maka.cu/1` gave it nowhere to land: `element_unknown` was defined as
"token is not in that snapshot", so the executor folded a *matching token with a
mismatched echo* into it, and §7.1 sent both to `stale_frame`. The host then read
"stale frame", re-observed, echoed the same wrong digest, and refused again —
with no field anywhere in the exchange saying which of the two had happened. That
is the collapse §4.1 refuses for snapshot states ("five distinct codes, not
one"), applied one level down.

Separated:

- `element_unknown` — the host quoted a token this snapshot never minted.
- `element_digest_mismatch` — the token is real, the echo is not the one recorded
  for it. Almost always the host pairing a token from one snapshot with a digest
  from another.
- `element_changed` — both the token and the echo are right, and the element
  itself moved on since observe. This is the only one of the three that describes
  the world; the other two describe the host.

The first two are host bookkeeping faults, so re-sending the same request against
the same frame cannot help and the host MUST NOT do it. Both still map to
`stale_frame` (§7.1) because that is the closest member of a closed set the
executor does not get to extend, and because a fresh `observe` does clear a
mixed-up pairing — but the host logs which code it received, since a repeated
`element_digest_mismatch` is a bug in the host and a repeated `element_changed`
is a busy screen. Which side changes: the executor, which today emits
`element_unknown` for both.

`dispatch_refused` covers both a path that was tried and an action that never
left the executor, and the declared fields tell them apart without a second code:
`path: "none"` with `detail.wouldRequirePath` means nothing was attempted, and a
concrete `path` means it was attempted and the OS said no. That distinction only
became expressible when refusals started carrying `path` (§1.1).

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
    "focusPolicy": "acquire",
    "action": { "kind": "type", "text": "hello" },
    "observeAfter": { "includeImage": false, "settle": "quiesce" }
  } }
```

```json
{ "kind": "type", "text": "hello" }
{ "kind": "key",  "key": "Return", "modifiers": ["command", "shift"] }
```

`modifiers` is a closed set: `command`, `shift`, `option`, `control`, `fn`.
`key` is one of the named keys below, or a single printable character in
U+0021–U+007E. The executor rejects anything else with `-32602` rather than
guessing.

```
Return  Tab  Space  Escape  Backspace  ForwardDelete
Up  Down  Left  Right  Home  End  PageUp  PageDown
F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12
```

Names are matched case-sensitively, exactly as spelled. The printable range
starts at U+0021 and not U+0020 because `Space` is the only spelling of the space
bar; two spellings of one key is the defect this whole section is about.

Two names were dropped from the `maka.cu/1` executor's set
(`hostNamedKeys`), each because it named a key ambiguously:

- `Enter` — a second name for `Return` with no stated difference between them.
- `Delete` — on a Mac keyboard the legend on the backspace key; in the
  xdotool vocabulary the *forward* delete. One string, two destructive meanings,
  no way to tell from the wire which the caller meant.

`Backspace` and `ForwardDelete` are unambiguous and are the only way to say it.

#### The host parses; the executor never sees a combination

Maka's callers do not hold this closed set. `CuAction.key` is
`{ type: 'key'; text: string }` and `CuSemanticAction.press_key` is
`{ key: string }` — free-form, xdotool-flavoured, `"cmd+a"` and `"shift+Tab"`
(`packages/core/src/computer-use.ts:161`,
`packages/runtime/src/computer-use-types.ts:143-147`). The `maka.cu/1` host
passed that string straight through as `key`, which the executor rejected with
`-32602`: a JSON-RPC error, which per §1.1 never describes the world, arriving in
answer to a request that described the world perfectly well.

**The host parses, before it sends.** The reasons are all one reason: Maka's
runtime owns every model-facing word (§13), so translating the model's dialect
into the protocol's vocabulary is its job, and an executor that accepts free-form
strings is an executor doing the loose parsing this protocol was written to
delete.

The grammar, exactly:

```
combo     := token ( "+" token )*
token     := modifier | key
modifier  := cmd | command | meta | super | ctrl | control
           | alt | opt | option | shift | fn | function
key       := named-key-alias | single character U+0021–U+007E
```

- Split on `"+"`. The **last** segment is the key; every earlier segment must be
  a modifier. A string with no `"+"` is a bare key.
- A trailing empty segment means the key is literally `"+"`: `"cmd++"` is
  command-plus, `"+"` is plus. Any other empty segment is unparseable.
- Modifier and alias matching is case-insensitive, and maps onto the wire's
  closed sets: `cmd`/`command`/`meta`/`super` → `command`;
  `ctrl`/`control` → `control`; `alt`/`opt`/`option` → `option`;
  `shift` → `shift`; `fn`/`function` → `fn`.
- Named-key aliases, also case-insensitive: `return`/`enter` → `Return`;
  `esc` → `Escape`; `spc`/`space` → `Space`; `pgup` → `PageUp`;
  `pgdn`/`pgdown` → `PageDown`; `up`/`arrowup` → `Up`, and the same for the other
  three arrows; `f1`…`f12` → `F1`…`F12`; every other named key is its own alias.
- A duplicated modifier is accepted once. Two non-modifier tokens is not a
  chord this protocol can express, and is unparseable.

**`delete` and `del` are deliberately unparseable.** They are the one alias a
reasonable parser would add and the one that must not exist: `delete` reads as
backspace to a Mac user and as forward-delete to xdotool, and picking either
deletes the wrong character. The host refuses and tells the model to say
`Backspace` or `ForwardDelete`.

**What an unparseable string does.** The host fails the action with
`unsupported_action` and a message naming the string it could not parse. It MUST
NOT drop the modifiers and send the key alone, MUST NOT pick a nearest match, and
MUST NOT send the raw string down and let the executor decide — a defaulted key
press is an action the user did not ask for and cannot see. Nothing reaches
`dispatch.key`.

An unparseable `key` arriving at the executor is therefore a host bug, and
`-32602` is the right answer to it.

Which side changes: the host, which gains the parser and stops forwarding
`action.key`/`action.text` verbatim. The executor drops `Enter` and `Delete` from
its named set and otherwise stays as it is — `KeyMapping.swift`'s xdotool parsing
remains an internal detail with no wire presence.

**`focusToken` is required and verified.** The executor MUST confirm that the
element currently focused in the target is the one named by `focusToken`, with a
matching digest, before posting any key event. `maka-cu` today types into
`snapshot.focusedElement` whatever that has become since the snapshot
(`ComputerUseService.swift:1366-1385`) — which is the same class of defect as
re-resolving an index. Focus mismatch is `focus_changed`, and it maps to
`target_changed`.

Key events are posted to the target pid. The executor MUST NOT activate the
application, raise its window, or change the frontmost app.

#### `focusPolicy` — verify focus, or take it

```json
"focusPolicy": "require" | "acquire"
```

Optional; **absent means `require`**. A closed set of two, and an unknown value
is `-32602` rather than a fallback to the stricter one — a host asking for a
third behaviour has a bug, and quietly answering it as `require` hides that bug
behind a refusal the host will read as "the user moved focus".

- **`require`** — the check described above, unchanged: the element named by
  `focusToken` must *already* be focused, and `focus_changed` otherwise. It is
  the default because taking focus is an action on the user's machine, and an
  executor that takes it when nobody asked is an executor doing something the
  host never wrote down.
- **`acquire`** — the executor writes `kAXFocused` on the bound element, then
  **re-reads** the focused element and proceeds only if it is now the one named.

`acquire` exists because without it the host's only way to focus a control was to
click it first, and a click is not a focus operation: on a button it is a press,
on a menu it opens the menu, and the model paid for a side effect it never asked
for. Maka's `press_key` promises the model an optional `element_id` that focuses
the control before the key is posted; `require` alone cannot keep that promise.

Two rules make `acquire` safe to have at all:

- **Verify, then acquire — never the other way round.** The token, the digest and
  the binding probe (§4.3) are all checked *before* the `kAXFocused` write. An
  executor that focused first would hand focus to whatever now sits at that
  reference, including an element whose digest has already stopped matching, and
  would then report `element_changed` having moved the user's focus.
- **The write's own success is not evidence.** Applications answer
  `AXError.success` and leave focus where it was. The only accepted proof is the
  re-read, and a failed acquisition — write refused, or write accepted and focus
  did not move — is `focus_changed` with no key posted. There is no "focus is
  probably close enough, post it anyway" path: a key that lands somewhere the
  request did not name is exactly the defect this section exists to delete.

`acquire` changes focus and nothing else. It still MUST NOT activate the
application, raise its window, or change the frontmost app.

### 6.5 Outcome, path, effect — the fields that used to be inferred

Four required fields on every dispatch result, all closed sets, none optional —
on the `ok: true` arm and the `ok: false` arm alike (§1.1):

| field | values |
| --- | --- |
| `outcome` | `ok`, `refused`, `failed`, `unknown` |
| `tier` | `ax`, `semantic-background`, `coordinate-background` |
| `path` | table in §6.3 |
| `effect` | `confirmed`, `unverifiable`, `suspected_noop` |

`outcome` is what selects the arm, so the two can never disagree:

| `outcome` | means | arm | `path` |
| --- | --- | --- | --- |
| `ok` | dispatched, and it completed | `ok: true` | the path used |
| `refused` | nothing was dispatched; a precondition or a policy said no | `ok: false` | `none` |
| `failed` | dispatched, the OS rejected it, nothing happened | `ok: false` | the path attempted |
| `unknown` | dispatched, and we cannot prove whether it landed | `ok: false` | the path attempted |

`ok: true` with any `outcome` other than `ok`, or `ok: false` with `outcome: ok`,
is a protocol violation. Every `ok: false` arm also carries the `error` object
whose code says which refusal it was (§6.2), and the pairing is fixed:
`outcome_unknown` accompanies `unknown`; `dispatch_refused` accompanies `failed`
when a path was attempted and `refused` when none was permitted; every other code
accompanies `refused`.

`tier` on a refusal is the tier the executor would have used, which is why
`path: none` pairs with any tier — the §6.3 pairing table constrains only a path
that was actually taken.

`effect` on a refusal is `unverifiable` with `verification.method: "none"`:
nothing was attempted, so nothing was checked, and §6.5's own distinction between
*never checked* and *checked and inconclusive* has to hold here too. `failed` and
`unknown` MUST NOT report `confirmed`.

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
{ "method": "screen.capture",
  "params": { "session": "s-01J…" } }
```

```json
{ "ok": true,
  "image": { "path": "…/cap_8812.png", "format": "png",
             "widthPx": 3024, "heightPx": 1964, "byteLength": 2_100_331,
             "sha256": "sha256:…", "scale": 2.0 },
  "displayId": "69732928",
  "capturedAt": 1753574400123 }
```

Whole-display capture, no snapshot, no binding, no state change. It exists
because `CuAction` has a `screenshot` member and the model may ask for one
without a target.

**`displayId` is optional, and absent means the main display.** It has to be
optional for the same reason the method exists: the request this method serves
is the one with no target, and a model that has observed nothing has not read
`displays[]` either. Requiring the field answered every untargeted screenshot
with `-32602`, so the one action the method was added for was the one action it
never performed. The result reports `displayId` whether or not the request
carried one, so a caller that declined to choose still knows exactly which
screen it is looking at.

Absent is not the same as wrong. A `displayId` that names no attached display is
`-32602` on the field, never a quiet fall back to the main one. Substituting a
display the caller did not ask for answers a question about display B with a
picture of display A, and the `displayId` in the result would agree with the
picture rather than with the request, so nothing downstream could tell. The
executor validates against the displays the window server reports, not against
`NSScreen` (§5.5).

The image is the display at the display's own pixel density, which is what the
example above shows: a Retina screen comes back at its full pixel count with
`scale: 2.0`, not at its point count with `scale: 1.0`. `SCDisplay`'s `width`
and `height` are points, and feeding them to a capture's pixel-sized output made
the compositor downscale to fit. Nothing about that frame is inconsistent — it
fills, and `1.0` describes it correctly — it is simply half the detail the
machine can give, for a method whose entire output is what the model can see.

### 6.7 Every image fills the size it declares

`image.widthPx` / `heightPx` describe the whole bitmap and every pixel of it is
content. An executor may not return a bitmap larger than the region it drew, and
`image.scale` must be the scaling the content actually has — not the scaling the
executor meant to apply, and not a display's `backingScaleFactor`.

This is a stated rule rather than an obvious consequence because the failure is
silent at every layer that could otherwise catch it. macOS takes the capture's
output size in pixels and the region it renders in points; hand it a buffer
larger than the content it is about to draw and it anchors that content at the
top-left and leaves the rest transparent instead of objecting. The PNG is
well-formed, its IHDR matches the declared `widthPx` / `heightPx`, and `sha256`
verifies. What reaches the model is a window shrunk into one corner of a mostly
empty image at half the resolution its `scale` claims, and a host that mirrors
the frame renders the empty part as a black margin — which is how this was
found, two layers away from the cause.

Every pixel statement in the protocol rests on this. `image_px` in §6.3 is read
from the image's origin, so a frame whose content is drawn at a different scale
than it declares puts every point dispatch off by the ratio between the two.

The executor therefore sizes the output buffer from the same source it renders
from, so the two cannot disagree, and measures `scale` from the bitmap it got
back (§5.3). Neither number is chosen twice.

---

## 7. Errors, mapping and bounds

### 7.1 Domain code → Maka error code

The host maps mechanically. No inference, no message matching.

| executor `code` | `ComputerUseErrorCode` |
| --- | --- |
| `snapshot_unknown`, `snapshot_expired`, `snapshot_evicted`, `element_unknown`, `element_digest_mismatch` | `stale_frame` |
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
| `dispatch_refused` | `dispatch_refused` |

**`COMPUTER_USE_ERROR_CODES` gains `dispatch_refused`.** This was the open
question `maka.cu/1` flagged and left open; leaving it open is what produced two
wrong answers. The set had no member meaning *"the executor attempted the action,
the OS refused it, and nothing happened"*, so `normalizeCuaDriverOutcome`'s
default branch sent it to `capture_failed` — telling the model a screenshot
failed when a button refused a press — and the `maka.cu/1` host, reading the same
table, chose `unsupported_action` instead.

Neither is salvageable. `capture_failed` names the wrong subsystem.
`unsupported_action` is already what `element_not_actionable` and
`element_disabled` map to, and those are decided *before* anything is dispatched:
collapsing them destroys the difference between "the element does not offer this"
and "it offered it, we tried, the OS said no", which is the difference between
"try something else" and "try again". That is the same collapse as §6.2, and it
gets the same answer — a new member.

What the host does with it:

- Surfaces it to the model as an outcome, with the executor's `detail` (enums and
  numbers only, §1.2) as evidence — including `wouldRequirePath` when nothing was
  attempted (§6.3).
- Does **not** re-observe automatically. A refused dispatch leaves the frame live
  (§4.1), so the model may retry against the same frame with different arguments.
- Does not treat it as a permission problem. `permission_missing` is a separate
  code precisely so that "TCC is revoked" and "this control said no" do not get
  the same recovery.

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
- `sha256` and `byteLength` are of the file's bytes as written, and `sha256` is
  written the one way §1.3 declares — `"sha256:"` then lowercase hex. The host
  MAY verify; a mismatch is a protocol violation, which is why the two sides
  cannot be allowed to disagree about the spelling. They did, and every
  screenshot mismatched.
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

## 10. Capture stream (reserved, not implemented in `maka.cu/2`)

Maka's picture-in-picture mirror repaints from the screenshot each action
returns. A live mirror needs a stream, and this channel is request/response —
so the stream is long-polling, the way Codex does it on its privileged channel
(`AppStartCapture` then repeated `AppNextCaptureUpdate`).

The method space is reserved now. In `maka.cu/2` all three return
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

What `maka.cu/2` already provides so this needs no protocol change:

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

**Start.** The host spawns the executor as a **direct child**, as
`<executable> host` — the subcommand is not optional. macOS attributes TCC
grants through the responsibility chain, and a helper launched via
`open`/LaunchServices gets its own attribution and its own prompts. The host
purges `imageDir`, spawns, sends `host.hello`, and treats any failure before a
successful `session.begin` as a start failure.

The subcommand is spelled out here because leaving it unsaid cost a debugging
session: the same executable also serves `doctor`, `list-apps` and `snapshot`
for a human at a terminal, and a bare invocation prints help and exits. Each
side picked for itself, they disagreed, and the first live run reported an
exhausted restart budget rather than a wrong argv. A host that spawns bare
sees the child die before the handshake; that is a host bug, not a protocol
negotiation, and there is nothing on the wire to catch it.

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
   The sibling case, a token that *is* in the quoted snapshot carrying a digest
   the snapshot did not record for it, is `element_digest_mismatch` — and the two
   vectors must produce different codes, because `maka.cu/1` produced one.
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

Refusals carry the declared fields (§1.1, §6.5):

25. Every `ok: false` dispatch result carries `outcome`, `tier`, `path`, `effect`
    and `verification`; the executor emits them on the refusal path, and a
    refusal missing any of them is rejected by the host as a protocol violation.
    Asserted on a binding refusal (`element_changed`), a policy refusal
    (`window_occluded`) and an attempted-and-rejected one (`dispatch_refused`).
26. A refusal reports `outcome: "refused"`, `path: "none"`,
    `effect: "unverifiable"` and `verification.method: "none"`; the host accepts
    it, maps the error code, and does **not** tear the executor down. The
    `maka.cu/1` host SIGKILLed on any non-`ok` outcome, so this vector fails
    against it.
27. `ok: true` with `outcome: "refused"`, and `ok: false` with `outcome: "ok"`,
    are both protocol violations.

Hashes (§1.3):

28. `element.digest`, `snapshot.windowDigest` and `image.sha256` all match
    `^sha256:[0-9a-f]{64}$` in the same response.
29. A host verifying an image prefixes its own digest before comparing, and a
    bare-hex `image.sha256` from the executor is a protocol violation rather than
    a mismatch. This is the vector that fails on `maka.cu/1`: bare hex on one
    side and prefixed on the other made every screenshot compare unequal, and the
    host's response to an unequal image is teardown.

Naming an app (§5.1):

30. `apps.list`, `window.list`, `snapshot.target` and the `apps.launch` result
    report the same `appId` for the same process.
31. `observe` with `{ "kind": "app", "app": "<appId of a bundled app>" }`
    resolves; the reviewer's reproduction — an `{app, windowId}` observation of a
    bundle-identified app — succeeds instead of being refused.
32. `observe` with an `app` that is a display name, not an `appId`, is
    `app_not_found`; the executor does not fall back to matching `appName` or
    `title`.
33. `apps.launch` by display name returns the resolved `appId`, and a subsequent
    `observe` with that `appId` resolves the launched window.

Keys (§6.4):

34. The host parses `"cmd+a"`, `"shift+Tab"`, `"Return"`, `"a"` and `"cmd++"`
    into `{ key, modifiers }` on the closed sets; the raw string never reaches
    the wire.
35. `"delete"`, `"del"`, `"cmd+"` (empty final segment that is not a trailing
    `"+"`), `"a+b"` and `"hyper+a"` fail the action with `unsupported_action`
    before any request is sent — no defaulted key press, no dropped modifier.
36. `dispatch.key` with `key: "cmd+a"` is `-32602` at the executor: the closed
    set is closed, and a host that sent it has a bug.

Coordinate space (§5.3):

37. For a window whose `bounds.origin` is not `(0, 0)`, the host's
    `CuObservedElement.frame` equals `element.frame + bounds.origin`. A snapshot
    passed through unconverted fails this by exactly the window origin, which is
    what the `maka.cu/1` host shipped.
38. The occlusion check and the agent cursor read the same converted rectangle,
    and an element at the far edge of a window at `x: 900` is not judged to be at
    `x: 0` on the desktop.

Refused, not unsupported (§7.1):

39. A `dispatch_refused` result reaches the model as `dispatch_refused`, not as
    `capture_failed` and not as `unsupported_action`, and the frame it quoted is
    still live afterwards.

Focus policy (§6.4):

40. `dispatch.key` with no `focusPolicy` behaves exactly as `require`: focus
    elsewhere is `focus_changed` with no key posted **and no `kAXFocused` write
    attempted**, and focus already on the named element posts the key, also
    without writing focus. With `focusPolicy: "acquire"` that same
    focus-elsewhere case writes focus onto the bound element and posts.
41. `acquire` against an element that does not end up focused — the write
    refused, and the write accepted while focus stays put — is `focus_changed`
    both times, with no key posted. The second half is the vector that fails
    against an executor which trusts the write instead of re-reading.
42. `focusPolicy` outside `require` / `acquire` is `-32602` naming the field,
    not a silent fallback to `require`.

Launching an app (§5.7):

43. `apps.launch` with `waitForWindowMs: 8000` resolves the application under a
    budget of 8000 ms, not under an executor-chosen one; a request that declares
    no budget still gets the executor's default. The vector that fails against an
    executor which waits its own five seconds for the process and then hands the
    caller's budget to the window wait — which is what refused a cold TextEdit at
    5571 ms.
44. An application that was started and had not registered within the budget is
    `timeout`; an application nothing on the machine answers to is
    `app_not_found`, and it is answered without spending the budget. The two
    codes must differ: one tells the model to wait, the other to try another
    name, and an executor that reports both as `app_not_found` sends the model
    hunting for an app it already launched.
45. An app on the executor's safety list is `unsupported_action`, and a launch
    the system refuses is `dispatch_refused`. Neither is `app_not_found`. This is
    the vector that fails against a handler which reaches the resolver through a
    `try?`, because that collapses every failure into the one code.
46. An application started after the executor appears in the next `apps.list`,
    and one that registers part-way through a launch budget resolves rather than
    timing out; `foregroundTaken` is the difference between a read before the
    launch and a read after it. The vector that fails against an executor reading
    `NSWorkspace.shared.runningApplications` or `frontmostApplication`, both of
    which are frozen at process start on any thread but the main one (§5.5) — and
    it only fails from a lane, so a check that runs on the main thread, or parks
    on anything that spins the main run loop, passes against the broken executor.

Capture geometry (§6.6, §6.7):

47. A window capture is drawn over the whole of the size it declares: the
    bounding box of the image's non-transparent pixels is the entire bitmap,
    under both capture scopes. The vector that fails against an executor which
    sizes the output buffer from `NSScreen.backingScaleFactor` instead of from
    the filter it renders through — a 674 × 408 pt window came back 1348 × 816
    px with the window in the top-left quarter, three quarters transparent, and
    `scale: 2.0` declared over content rendered at 1.0. It can only fail on a
    machine whose displays do not all share one backing scale, because where the
    guess happens to be right there is nothing to catch; that is why it is a
    live vector and why it sweeps every window on screen rather than one.
48. `screen.capture` with no `displayId` captures the main display and reports
    the id it used. The vector that fails against an executor which decodes the
    field as required: `CuAction.screenshot` is defined to arrive with no
    target, so a required `displayId` makes `-32602` the answer to every
    screenshot the model actually asks for.
49. `screen.capture` naming a display that is not attached is `-32602` on
    `displayId`, and no image is written. This vector and 48 have to be read as
    a pair — an executor that satisfies 48 by defaulting whenever the lookup
    fails passes 48 and fails 49, and it fails it by returning a picture of the
    main display under the display id the caller asked for.

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
- **No `bundleId` alongside `appId`.** One namespace, §5.1.

---

## 14. Open questions

`maka.cu/1` referred to this section from §4.4 and §7.1 and never contained it,
which is how its one flagged question stayed open long enough for two
implementations to answer it differently. What remains open is listed here and
nowhere else.

- **The Electron/Chromium `element_released` rate is unmeasured.** §4.4 item 2
  states that tree-rebuilding applications can fail E1 on a control that is
  visibly present, and that the correct host response is to re-observe. Nobody
  has measured how often that happens per action in a real Electron window. Until
  someone does, the host's retry budget for `element_released` is a guess, and
  the protocol says nothing about what that budget should be.

Closed since `maka.cu/1`: the `dispatch_refused` mapping, now §7.1.
