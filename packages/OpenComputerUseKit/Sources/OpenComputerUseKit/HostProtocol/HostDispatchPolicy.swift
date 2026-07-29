import CoreGraphics
import Foundation

/// The decisions §6 takes away from the host: which path may carry an action,
/// which pairings are legal, when occlusion refuses, and what `effect` a piece of
/// evidence is allowed to claim. All of it is pure so it can be tested without a
/// desktop, and all of it is declared on the wire rather than inferred.

// MARK: - Requests

public enum HostElementAction: Equatable, Sendable {
    case click(button: HostMouseButton, count: Int)
    case setValue(String)
    case selectText(String)
    case secondaryAction(HostElementActionName)
    case scroll(direction: HostScrollDirection, pages: Double)

    var requiredElementAction: HostElementActionName? {
        switch self {
        case .click(.left, _):
            return .press
        case .click(.right, _):
            return .showMenu
        case .click(.middle, _):
            return nil
        case .secondaryAction(let name):
            return name
        case .setValue, .selectText, .scroll:
            return nil
        }
    }
}

public enum HostPointAction: Equatable, Sendable {
    case move
    case leftClick(count: Int)
    case rightClick(count: Int)
    case middleClick(count: Int)
    case mouseDown
    case mouseUp
    case drag
    case scroll(direction: HostScrollDirection, pages: Double)

    var needsStartPoint: Bool {
        self == .drag
    }
}

public enum HostKeyAction: Equatable, Sendable {
    case type(String)
    case key(name: String, modifiers: [HostKeyModifier])
}

// MARK: - Path selection

/// §6.3 — path selection is declared, not discovered. When `allowGlobalPointer`
/// is false and no permitted path can reach the target, the executor refuses; it
/// must never fall back. This is the invariant Maka refuses to trade: no cursor
/// warp, no z-order change.
public func hostPointDispatchPath(
    action: HostPointAction,
    point: CGPoint,
    startPoint: CGPoint?,
    windowBounds: CGRect,
    allowGlobalPointer: Bool
) -> Result<HostDispatchPath, HostDomainError> {
    // A pointer *move* has no pid-bound form: the only way to make the cursor
    // appear somewhere is to warp the system cursor, which is the one thing this
    // executor will not do on Maka's behalf.
    if action == .move {
        return allowGlobalPointer
            ? .success(.cgEventGlobal)
            : .failure(HostDomainError(.dispatchRefused, detail: .wouldRequirePath(.cgEventGlobal)))
    }

    guard windowBounds.contains(point) else {
        return .failure(HostDomainError(.invalidPoint))
    }

    if action.needsStartPoint {
        guard let startPoint else {
            return .failure(HostDomainError(.invalidPoint))
        }

        // A drag that begins outside the target window crosses a window boundary,
        // and only a global-tap drag is delivered to whichever window happens to
        // be under each intermediate point.
        guard windowBounds.contains(startPoint) else {
            return allowGlobalPointer
                ? .success(.cgEventGlobal)
                : .failure(HostDomainError(.dispatchRefused, detail: .wouldRequirePath(.cgEventGlobal)))
        }
    }

    return .success(.cgEventPid)
}

/// §6.3 — the host MUST reject an inconsistent `tier`/`path` pair as a protocol
/// violation rather than prefer one. The executor never emits one.
public func hostTierIsConsistent(tier: HostDispatchTier, path: HostDispatchPath) -> Bool {
    guard let expected = path.tier else {
        // `path: none` only ever accompanies a refusal, which reports the tier it
        // would have used; any tier is consistent with "nothing was dispatched".
        return true
    }

    return expected == tier
}

// MARK: - Occlusion

/// §6.2 — occlusion is a separate check from identity, with a separate code.
///
/// `same_app` is the default for element dispatch because a semantic dispatch
/// addresses an element, not a pixel: a foreign window stacked above it has no
/// bearing on whether `AXPress` reaches it. Treating foreign windows as occlusion
/// made background operation impossible in the case that matters most — an app
/// started by `apps.launch` begins at the bottom of the z-order, so every window
/// on the user's screen sat above it and every semantic click was refused.
public func hostIsOccluded(
    policy: HostOcclusionPolicy,
    targetPid: pid_t,
    targetPoint: CGPoint,
    obscuringWindows: [(pid: pid_t, rect: CGRect)]
) -> Bool {
    switch policy {
    case .none:
        return false
    case .any:
        return obscuringWindows.contains { $0.rect.contains(targetPoint) }
    case .sameApp:
        return obscuringWindows.contains { $0.pid == targetPid && $0.rect.contains(targetPoint) }
    }
}

// MARK: - Effect rules

public struct HostEffectVerdict: Equatable, Sendable {
    public let effect: HostDispatchEffect
    public let verification: HostVerification
}

/// §6.5 — a bare `AXUIElementPerformAction` returning `.success` is not
/// confirmation. It means the message was accepted, not that anything moved.
public func hostEffectFromActionResult() -> HostEffectVerdict {
    HostEffectVerdict(
        effect: .unverifiable,
        verification: HostVerification(method: .actionResult, observedChange: false)
    )
}

/// §6.5 — `set_value` MUST read the value back. Equal to the requested value is
/// `confirmed`; equal to the *previous* value is `suspected_noop`; anything else
/// is `unverifiable`, because a third value means something else wrote it.
public func hostEffectFromValueReadback(
    requested: String,
    previous: String?,
    readback: String?
) -> HostEffectVerdict {
    guard let readback else {
        return HostEffectVerdict(
            effect: .unverifiable,
            verification: HostVerification(method: .valueReadback, observedChange: false)
        )
    }

    if readback == requested {
        return HostEffectVerdict(
            effect: .confirmed,
            verification: HostVerification(method: .valueReadback, observedChange: readback != previous)
        )
    }

    if readback == previous {
        return HostEffectVerdict(
            effect: .suspectedNoop,
            verification: HostVerification(method: .valueReadback, observedChange: false)
        )
    }

    return HostEffectVerdict(
        effect: .unverifiable,
        verification: HostVerification(method: .valueReadback, observedChange: true)
    )
}

public func hostEffectFromSelectionReadback(
    requested: String,
    readback: String?
) -> HostEffectVerdict {
    guard let readback else {
        return HostEffectVerdict(
            effect: .unverifiable,
            verification: HostVerification(method: .selectionReadback, observedChange: false)
        )
    }

    return HostEffectVerdict(
        effect: readback == requested ? .confirmed : .unverifiable,
        verification: HostVerification(method: .selectionReadback, observedChange: !readback.isEmpty)
    )
}

/// §6.5 — a click MAY report `confirmed` from a window-digest delta, but only
/// when `settle: "quiesce"` gave a change time to appear. With `settle: "none"`
/// no time was given, so absence of change is not evidence and neither is its
/// presence attributable to this action.
public func hostEffectFromTreeDelta(
    settle: HostSettleMode,
    digestBefore: String,
    digestAfter: String?
) -> HostEffectVerdict {
    guard settle == .quiesce, let digestAfter else {
        return HostEffectVerdict(
            effect: .unverifiable,
            verification: HostVerification(method: .actionResult, observedChange: false)
        )
    }

    let changed = digestAfter != digestBefore
    return HostEffectVerdict(
        effect: changed ? .confirmed : .unverifiable,
        verification: HostVerification(method: .treeDelta, observedChange: changed)
    )
}

// MARK: - Response budget

/// §7.5 — halve `maxElements` and retry up to three times, reporting the
/// reduction through `truncated.elements`. Never drop fields to fit.
public func hostFitResponse<Payload>(
    maxElements: Int,
    limitBytes: Int,
    build: (Int) throws -> (payload: Payload, encoded: Data)
) rethrows -> Result<(payload: Payload, encoded: Data), HostDomainError> {
    var elements = maxElements

    for attempt in 0...3 {
        let candidate = try build(elements)
        if candidate.encoded.count <= limitBytes {
            return .success(candidate)
        }

        if attempt == 3 {
            return .failure(
                HostDomainError(
                    .responseTooLarge,
                    detail: .responseSize(bytes: candidate.encoded.count, limit: limitBytes)
                )
            )
        }

        elements = max(1, elements / 2)
    }

    return .failure(HostDomainError(.responseTooLarge, detail: .responseSize(bytes: 0, limit: limitBytes)))
}
