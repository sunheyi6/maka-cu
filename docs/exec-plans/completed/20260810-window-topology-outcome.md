# Confirm press actions through window topology

## Goal

Prevent a successful modal/window open or close from being reported as
`outcome_unknown` when AppKit changes window topology during `AXPress`.

## Scope

- Include single left press, `press`, and `cancel`.
- Require the target PID's exact on-screen window ID set to change in two
  consecutive samples within 5 seconds.
- Preserve `postObservationError: window_gone`.
- Keep every other unknown outcome unchanged.
- Restore the exact previous frontmost PID only when the target app activates
  itself; never override a user switch to a third app. Verify the result with
  the independent live foreground sentinel.

## Risk

An unrelated same-app window change could be mistaken for the requested action. The
recovery is therefore limited to one press-like action and the exact window
bound by the quoted snapshot. Multi-click, value, text, scroll and window
management actions are excluded.

## Verification

- `swift test`: 323 tests, 26 opt-in skips, 0 failures.
- CUA Lab modal/secondary matrix: 5 consecutive passes.
- Modal open/close and secondary button/scroll/close all used `ax_action`.
- Secondary scroll oracle reached 140.
- The CUA Lab target never became frontmost.
