# WebContent frame reflow refetch

## Goal

Keep a direct WebContent element dispatchable when its retained AX reference is
still live but Web layout changes only its frame between observe and dispatch.

## Boundary

- Accept only renderer-owned `element_changed` with exactly
  `changed: ["frame"]`.
- Reuse the existing unique identity-preserving refetch.
- Preserve host and renderer PID/start-time generations.
- Keep missing and ambiguous replacements fail closed.
- Continue renderer clicks through `skylight_pid`.
- Do not accept role, name, identifier, action, ancestor, sibling, or value
  changes.
- Keep native AX frame changes fail closed.

## Verification

- `HostDispatchTests` covers a direct WebContent binding whose frame changes,
  refetches uniquely, and dispatches through `skylight_pid` to the renderer PID.
- The exact release binary is exercised by the shared CUA Lab Web matrix for
  trusted OOP clicks, one down/up pair, slider 42, scroll 76, and zero
  wrong-target stale/refetch effects.
- Full `swift test` remains the source merge gate.

## Status

- [x] Add frame-only eligibility to direct binding verification.
- [x] Preserve WebContent dispatch classification after refetch.
- [x] Add focused direct WebContent regression coverage.
- [x] Document the protocol boundary.
