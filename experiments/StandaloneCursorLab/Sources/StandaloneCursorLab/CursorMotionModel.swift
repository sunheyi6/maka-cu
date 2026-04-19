import CoreGraphics
import Foundation

struct CursorMotionParameters: Equatable {
    var startHandle: CGFloat = 0.29
    var endHandle: CGFloat = 0.08
    var arcSize: CGFloat = 0.06
    var arcFlow: CGFloat = 0.64
    var spring: CGFloat = 0.53

    static let `default` = CursorMotionParameters()
}

struct CursorMotionCandidate: Identifiable, Equatable {
    let id: String
    let path: CursorMotionPath
    let score: CGFloat
    let family: String
}

struct CursorPathSample {
    let point: CGPoint
    let tangent: CGVector
}

struct CursorMotionPath: Equatable {
    let start: CGPoint
    let control1: CGPoint
    let control2: CGPoint
    let end: CGPoint
    let arcHeight: CGFloat
    let arcIn: CGFloat
    let arcOut: CGFloat

    func point(at t: CGFloat) -> CGPoint {
        let omt = 1 - t
        let omt2 = omt * omt
        let t2 = t * t

        return CGPoint(
            x: (omt2 * omt * start.x)
                + (3 * omt2 * t * control1.x)
                + (3 * omt * t2 * control2.x)
                + (t2 * t * end.x),
            y: (omt2 * omt * start.y)
                + (3 * omt2 * t * control1.y)
                + (3 * omt * t2 * control2.y)
                + (t2 * t * end.y)
        )
    }

    func tangent(at t: CGFloat) -> CGVector {
        let omt = 1 - t
        return CGVector(
            dx: (3 * omt * omt * (control1.x - start.x))
                + (6 * omt * t * (control2.x - control1.x))
                + (3 * t * t * (end.x - control2.x)),
            dy: (3 * omt * omt * (control1.y - start.y))
                + (6 * omt * t * (control2.y - control1.y))
                + (3 * t * t * (end.y - control2.y))
        )
    }

    func sample(at t: CGFloat) -> CursorPathSample {
        CursorPathSample(point: point(at: t), tangent: tangent(at: max(0.001, min(t, 0.999))))
    }

    func secondDerivative(at t: CGFloat) -> CGVector {
        let omt = 1 - t
        return CGVector(
            dx: (6 * omt * (control2.x - (2 * control1.x) + start.x))
                + (6 * t * (end.x - (2 * control2.x) + control1.x)),
            dy: (6 * omt * (control2.y - (2 * control1.y) + start.y))
                + (6 * t * (end.y - (2 * control2.y) + control1.y))
        )
    }

    func curvature(at t: CGFloat) -> CGFloat {
        let derivative = tangent(at: t)
        let second = secondDerivative(at: t)
        let numerator = abs((derivative.dx * second.dy) - (derivative.dy * second.dx))
        let denominator = pow(max((derivative.dx * derivative.dx) + (derivative.dy * derivative.dy), 0.001), 1.5)
        return numerator / denominator
    }

    var cgPath: CGPath {
        let path = CGMutablePath()
        path.move(to: start)
        path.addCurve(to: end, control1: control1, control2: control2)
        return path
    }
}

enum CursorMotionPathBuilder {
    private static let baseCursorHeading = CursorGlyphCalibration.neutralHeading

    static func makePath(
        from start: CGPoint,
        to end: CGPoint,
        parameters: CursorMotionParameters,
        startRotation: CGFloat = 0,
        endRotation: CGFloat = CursorGlyphCalibration.restingRotation
    ) -> CursorMotionPath {
        let metrics = MotionMetrics(start: start, end: end)
        let descriptor = descriptors(for: metrics).max { lhs, rhs in
            score(descriptor: lhs, metrics: metrics, parameters: parameters) < score(descriptor: rhs, metrics: metrics, parameters: parameters)
        } ?? descriptors(for: metrics)[0]
        return makePath(
            from: start,
            to: end,
            parameters: parameters,
            descriptor: descriptor,
            metrics: metrics,
            startRotation: startRotation,
            endRotation: endRotation
        )
    }

    static func makeCandidatePaths(
        from start: CGPoint,
        to end: CGPoint,
        parameters: CursorMotionParameters,
        startRotation: CGFloat = 0,
        endRotation: CGFloat = CursorGlyphCalibration.restingRotation
    ) -> [CursorMotionCandidate] {
        let metrics = MotionMetrics(start: start, end: end)
        return descriptors(for: metrics).map { descriptor in
            let path = makePath(
                from: start,
                to: end,
                parameters: parameters,
                descriptor: descriptor,
                metrics: metrics,
                startRotation: startRotation,
                endRotation: endRotation
            )
            return CursorMotionCandidate(
                id: descriptor.id,
                path: path,
                score: score(descriptor: descriptor, metrics: metrics, parameters: parameters),
                family: descriptor.family
            )
        }
        .sorted { lhs, rhs in
            lhs.score > rhs.score
        }
    }

    private static func makePath(
        from start: CGPoint,
        to end: CGPoint,
        parameters: CursorMotionParameters,
        descriptor: MotionDescriptor,
        metrics: MotionMetrics,
        startRotation: CGFloat,
        endRotation: CGFloat
    ) -> CursorMotionPath {
        let distance = metrics.distance
        let direction = metrics.direction
        let normal = metrics.normal
        let resolvedFlow = (parameters.arcFlow + descriptor.flowShift).clamped(to: 0...1)
        let flowBias = (resolvedFlow - 0.5) * distance * 0.18

        let baseStartReach = distance * (0.10 + parameters.startHandle * 0.56)
        let baseEndReach = distance * (0.11 + parameters.endHandle * 0.62)
        let distanceLift = 0.68 + (metrics.farFactor * 0.56)
        let baseArcHeight = min(
            max(distance * (0.10 + parameters.arcSize * 0.92) * descriptor.arcScale * distanceLift, 20),
            distance * 0.96
        )

        let sideSign = descriptor.side
        let arcVector = CGPoint(
            x: normal.dx * baseArcHeight * sideSign,
            y: normal.dy * baseArcHeight * sideSign
        )

        let startForward = headingVector(rotation: startRotation)
        let endForward = headingVector(rotation: endRotation)
        let startGuide = resolvedGuide(
            line: direction,
            forward: startForward,
            normal: normal,
            sideSign: sideSign,
            lineWeight: descriptor.startLineWeight,
            headingWeight: descriptor.startHeadingWeight,
            normalBias: descriptor.startGuideNormalBias
        )
        let endGuide = resolvedGuide(
            line: direction,
            forward: endForward,
            normal: normal,
            sideSign: sideSign,
            lineWeight: descriptor.endLineWeight,
            headingWeight: descriptor.endHeadingWeight,
            normalBias: descriptor.endGuideNormalBias
        )

        let startReach = max(baseStartReach * descriptor.startReachScale + flowBias * descriptor.startFlowWeight, 12)
        let endReach = max(baseEndReach * descriptor.endReachScale - flowBias * descriptor.endFlowWeight, 12)
        let control1Base = CGPoint(
            x: start.x + startGuide.dx * startReach,
            y: start.y + startGuide.dy * startReach
        )
        let control2Base = CGPoint(
            x: end.x - endGuide.dx * endReach,
            y: end.y - endGuide.dy * endReach
        )

        let control1 = CGPoint(
            x: control1Base.x + arcVector.x * descriptor.startNormalScale,
            y: control1Base.y + arcVector.y * descriptor.startNormalScale
        )
        let control2 = CGPoint(
            x: control2Base.x + arcVector.x * descriptor.endNormalScale,
            y: control2Base.y + arcVector.y * descriptor.endNormalScale
        )

        let resolvedArcHeight = baseArcHeight * max(
            abs(descriptor.startNormalScale),
            abs(descriptor.endNormalScale),
            0.12
        )
        let arcIn = abs(descriptor.startNormalScale).clamped(to: 0.12...1.28)
        let arcOut = abs(descriptor.endNormalScale).clamped(to: 0.12...1.28)

        return CursorMotionPath(start: start, control1: control1, control2: control2, end: end, arcHeight: resolvedArcHeight, arcIn: arcIn, arcOut: arcOut)
    }

    private static func score(descriptor: MotionDescriptor, metrics: MotionMetrics, parameters: CursorMotionParameters) -> CGFloat {
        let sideAffinity = descriptor.side == preferredSide(for: metrics) ? 0.04 : -0.02
        let flowEnergy = abs(parameters.arcFlow - 0.5) * 0.08
        let handleEnergy = max(parameters.startHandle, parameters.endHandle) * 0.06

        switch descriptor.family {
        case "turn":
            return 0.36 + (metrics.farFactor * 0.28) + (metrics.horizontalFactor * 0.18) + (metrics.diagonalFactor * 0.10) + handleEnergy + sideAffinity
        case "brake":
            return 0.35 + (metrics.farFactor * 0.20) + (metrics.horizontalFactor * 0.12) + (parameters.spring * 0.06) + flowEnergy
        case "orbit":
            return 0.28 + (metrics.horizontalFactor * 0.20) + (metrics.farFactor * 0.28) + sideAffinity + flowEnergy
        case "ribbon":
            return 0.24 + (metrics.diagonalFactor * 0.26) + (metrics.farFactor * 0.10) + flowEnergy
        case "slingshot":
            return 0.22 + (metrics.closeFactor * 0.10) + (metrics.diagonalFactor * 0.20) + (metrics.farFactor * 0.08) + sideAffinity
        case "hook":
            return 0.20 + (metrics.closeFactor * 0.22) + (metrics.verticalFactor * 0.18)
        case "snap":
            return 0.18 + (metrics.closeFactor * 0.26) + (metrics.horizontalFactor * 0.08)
        case "direct":
            return 0.14 + (metrics.closeFactor * 0.20) - (metrics.farFactor * 0.28)
        default:
            return 0.12
        }
    }

    private static func descriptors(for metrics: MotionMetrics) -> [MotionDescriptor] {
        let orbitScale = 0.84 + (metrics.farFactor * 0.34)
        let tightScale = 0.58 + (metrics.closeFactor * 0.22)
        let turnaroundScale = 0.92 + (metrics.farFactor * 0.34)
        let brakingScale = 0.76 + (metrics.farFactor * 0.28)

        return [
            MotionDescriptor(
                id: "turn-high",
                family: "turn",
                side: 1,
                startReachScale: 1.30,
                endReachScale: 1.34,
                startLineWeight: -0.26,
                endLineWeight: -0.10,
                startHeadingWeight: 1.56,
                endHeadingWeight: 1.34,
                startNormalScale: 0.52,
                endNormalScale: 0.02,
                startGuideNormalBias: 0.36,
                endGuideNormalBias: 0.24,
                startFlowWeight: -0.34,
                endFlowWeight: 0.26,
                flowShift: -0.08,
                arcScale: turnaroundScale
            ),
            MotionDescriptor(
                id: "turn-low",
                family: "turn",
                side: -1,
                startReachScale: 1.26,
                endReachScale: 1.38,
                startLineWeight: -0.30,
                endLineWeight: -0.12,
                startHeadingWeight: 1.52,
                endHeadingWeight: 1.38,
                startNormalScale: 0.50,
                endNormalScale: 0.04,
                startGuideNormalBias: 0.34,
                endGuideNormalBias: 0.24,
                startFlowWeight: -0.30,
                endFlowWeight: 0.28,
                flowShift: 0.08,
                arcScale: turnaroundScale * 0.96
            ),
            MotionDescriptor(
                id: "brake-high",
                family: "brake",
                side: 1,
                startReachScale: 0.92,
                endReachScale: 1.48,
                startLineWeight: 0.52,
                endLineWeight: -0.28,
                startHeadingWeight: 0.68,
                endHeadingWeight: 1.66,
                startNormalScale: 0.20,
                endNormalScale: 0.24,
                startGuideNormalBias: 0.10,
                endGuideNormalBias: 0.36,
                startFlowWeight: 0.10,
                endFlowWeight: 0.42,
                flowShift: -0.04,
                arcScale: brakingScale
            ),
            MotionDescriptor(
                id: "brake-low",
                family: "brake",
                side: -1,
                startReachScale: 0.96,
                endReachScale: 1.52,
                startLineWeight: 0.48,
                endLineWeight: -0.32,
                startHeadingWeight: 0.70,
                endHeadingWeight: 1.72,
                startNormalScale: 0.22,
                endNormalScale: 0.28,
                startGuideNormalBias: 0.12,
                endGuideNormalBias: 0.38,
                startFlowWeight: 0.12,
                endFlowWeight: 0.44,
                flowShift: 0.04,
                arcScale: brakingScale * 0.94
            ),
            MotionDescriptor(
                id: "orbit-high",
                family: "orbit",
                side: 1,
                startReachScale: 0.92,
                endReachScale: 1.02,
                startLineWeight: 0.72,
                endLineWeight: 0.82,
                startHeadingWeight: 0.34,
                endHeadingWeight: 0.24,
                startNormalScale: 1.24,
                endNormalScale: 1.08,
                startGuideNormalBias: 0.18,
                endGuideNormalBias: 0.08,
                startFlowWeight: 0.40,
                endFlowWeight: 0.18,
                flowShift: -0.10,
                arcScale: orbitScale
            ),
            MotionDescriptor(
                id: "orbit-low",
                family: "orbit",
                side: -1,
                startReachScale: 0.88,
                endReachScale: 1.04,
                startLineWeight: 0.68,
                endLineWeight: 0.84,
                startHeadingWeight: 0.30,
                endHeadingWeight: 0.22,
                startNormalScale: 1.18,
                endNormalScale: 1.02,
                startGuideNormalBias: 0.16,
                endGuideNormalBias: 0.08,
                startFlowWeight: 0.34,
                endFlowWeight: 0.14,
                flowShift: 0.10,
                arcScale: orbitScale * 0.94
            ),
            MotionDescriptor(
                id: "ribbon-high",
                family: "ribbon",
                side: 1,
                startReachScale: 0.98,
                endReachScale: 0.90,
                startLineWeight: 0.74,
                endLineWeight: 0.34,
                startHeadingWeight: 0.28,
                endHeadingWeight: 0.56,
                startNormalScale: 0.78,
                endNormalScale: -0.56,
                startGuideNormalBias: 0.10,
                endGuideNormalBias: -0.22,
                startFlowWeight: 0.12,
                endFlowWeight: -0.18,
                flowShift: 0.06,
                arcScale: 0.82 + (metrics.diagonalFactor * 0.24)
            ),
            MotionDescriptor(
                id: "ribbon-low",
                family: "ribbon",
                side: -1,
                startReachScale: 0.94,
                endReachScale: 0.92,
                startLineWeight: 0.70,
                endLineWeight: 0.36,
                startHeadingWeight: 0.28,
                endHeadingWeight: 0.60,
                startNormalScale: 0.74,
                endNormalScale: -0.52,
                startGuideNormalBias: 0.10,
                endGuideNormalBias: -0.20,
                startFlowWeight: 0.10,
                endFlowWeight: -0.16,
                flowShift: -0.06,
                arcScale: 0.80 + (metrics.diagonalFactor * 0.22)
            ),
            MotionDescriptor(
                id: "slingshot-high",
                family: "slingshot",
                side: 1,
                startReachScale: 1.12,
                endReachScale: 1.00,
                startLineWeight: -0.24,
                endLineWeight: 0.86,
                startHeadingWeight: 1.00,
                endHeadingWeight: 0.24,
                startNormalScale: 0.48,
                endNormalScale: 0.94,
                startGuideNormalBias: 0.20,
                endGuideNormalBias: 0.08,
                startFlowWeight: -0.46,
                endFlowWeight: 0.24,
                flowShift: -0.12,
                arcScale: 0.74 + (metrics.diagonalFactor * 0.18)
            ),
            MotionDescriptor(
                id: "slingshot-low",
                family: "slingshot",
                side: -1,
                startReachScale: 1.16,
                endReachScale: 1.02,
                startLineWeight: -0.28,
                endLineWeight: 0.88,
                startHeadingWeight: 1.04,
                endHeadingWeight: 0.24,
                startNormalScale: 0.44,
                endNormalScale: 0.98,
                startGuideNormalBias: 0.22,
                endGuideNormalBias: 0.10,
                startFlowWeight: -0.42,
                endFlowWeight: 0.22,
                flowShift: 0.12,
                arcScale: 0.72 + (metrics.diagonalFactor * 0.18)
            ),
            MotionDescriptor(
                id: "hook-upper",
                family: "hook",
                side: 1,
                startReachScale: 0.90,
                endReachScale: 0.76,
                startLineWeight: -0.44,
                endLineWeight: 0.30,
                startHeadingWeight: 0.92,
                endHeadingWeight: 0.18,
                startNormalScale: -0.36,
                endNormalScale: 0.30,
                startGuideNormalBias: -0.20,
                endGuideNormalBias: 0.16,
                startFlowWeight: -0.52,
                endFlowWeight: 0.18,
                flowShift: -0.10,
                arcScale: tightScale
            ),
            MotionDescriptor(
                id: "hook-lower",
                family: "hook",
                side: -1,
                startReachScale: 0.88,
                endReachScale: 0.74,
                startLineWeight: -0.40,
                endLineWeight: 0.28,
                startHeadingWeight: 0.88,
                endHeadingWeight: 0.18,
                startNormalScale: -0.34,
                endNormalScale: 0.26,
                startGuideNormalBias: -0.18,
                endGuideNormalBias: 0.16,
                startFlowWeight: -0.48,
                endFlowWeight: 0.16,
                flowShift: 0.10,
                arcScale: tightScale * 0.96
            ),
            MotionDescriptor(
                id: "snap",
                family: "snap",
                side: preferredSide(for: metrics),
                startReachScale: 1.10,
                endReachScale: 0.72,
                startLineWeight: 1.08,
                endLineWeight: -0.22,
                startHeadingWeight: 0.22,
                endHeadingWeight: 0.74,
                startNormalScale: 0.20,
                endNormalScale: -0.34,
                startGuideNormalBias: 0.06,
                endGuideNormalBias: -0.16,
                startFlowWeight: 0.28,
                endFlowWeight: -0.34,
                flowShift: 0.04,
                arcScale: 0.54 + (metrics.closeFactor * 0.20)
            ),
            MotionDescriptor(
                id: "direct",
                family: "direct",
                side: preferredSide(for: metrics),
                startReachScale: 0.94,
                endReachScale: 0.94,
                startLineWeight: 1.16,
                endLineWeight: 1.06,
                startHeadingWeight: 0.02,
                endHeadingWeight: 0.02,
                startNormalScale: 0.02,
                endNormalScale: 0.02,
                startGuideNormalBias: 0,
                endGuideNormalBias: 0,
                startFlowWeight: 0.06,
                endFlowWeight: 0.06,
                flowShift: 0,
                arcScale: 0.20
            ),
        ]
    }

    private static func preferredSide(for metrics: MotionMetrics) -> CGFloat {
        if abs(metrics.dy) > abs(metrics.dx) * 0.72 {
            return metrics.dy > 0 ? -1 : 1
        }
        return metrics.dx >= 0 ? 1 : -1
    }

    private static func headingVector(rotation: CGFloat) -> CGVector {
        let angle = baseCursorHeading + rotation
        return CGVector(dx: cos(angle), dy: sin(angle))
    }

    private static func resolvedGuide(
        line: CGVector,
        forward: CGVector,
        normal: CGVector,
        sideSign: CGFloat,
        lineWeight: CGFloat,
        headingWeight: CGFloat,
        normalBias: CGFloat
    ) -> CGVector {
        normalized(CGVector(
            dx: (line.dx * lineWeight) + (forward.dx * headingWeight) + (normal.dx * normalBias * sideSign),
            dy: (line.dy * lineWeight) + (forward.dy * headingWeight) + (normal.dy * normalBias * sideSign)
        ))
    }

    private static func normalized(_ vector: CGVector) -> CGVector {
        let length = max(hypot(vector.dx, vector.dy), 0.001)
        return CGVector(dx: vector.dx / length, dy: vector.dy / length)
    }

    private struct MotionDescriptor {
        let id: String
        let family: String
        let side: CGFloat
        let startReachScale: CGFloat
        let endReachScale: CGFloat
        let startLineWeight: CGFloat
        let endLineWeight: CGFloat
        let startHeadingWeight: CGFloat
        let endHeadingWeight: CGFloat
        let startNormalScale: CGFloat
        let endNormalScale: CGFloat
        let startGuideNormalBias: CGFloat
        let endGuideNormalBias: CGFloat
        let startFlowWeight: CGFloat
        let endFlowWeight: CGFloat
        let flowShift: CGFloat
        let arcScale: CGFloat
    }

    private struct MotionMetrics {
        let start: CGPoint
        let end: CGPoint
        let dx: CGFloat
        let dy: CGFloat
        let distance: CGFloat
        let direction: CGVector
        let normal: CGVector
        let horizontalFactor: CGFloat
        let verticalFactor: CGFloat
        let diagonalFactor: CGFloat
        let closeFactor: CGFloat
        let farFactor: CGFloat

        init(start: CGPoint, end: CGPoint) {
            self.start = start
            self.end = end
            dx = end.x - start.x
            dy = end.y - start.y
            distance = max(hypot(dx, dy), 1)
            direction = normalized(CGVector(dx: dx, dy: dy))
            normal = normalized(CGVector(dx: -direction.dy, dy: direction.dx))
            horizontalFactor = abs(dx) / distance
            verticalFactor = abs(dy) / distance
            diagonalFactor = min(horizontalFactor, verticalFactor) * 2
            closeFactor = (1 - (distance / 280)).clamped(to: 0...1)
            farFactor = ((distance - 180) / 540).clamped(to: 0...1)
        }
    }
}

struct CursorSpringParameters: Equatable {
    let durationScale: CGFloat
    let headingResponse: CGFloat
    let finishRelaxation: CGFloat

    static func from(_ spring: CGFloat) -> CursorSpringParameters {
        CursorSpringParameters(
            durationScale: 1.08 - (spring * 0.26),
            headingResponse: 0.18 + (spring * 0.38),
            finishRelaxation: 0.10 + ((1 - spring) * 0.10)
        )
    }
}

struct CursorMotionState {
    let point: CGPoint
    let rotation: CGFloat
    let trailProgress: CGFloat
    let isSettled: Bool
}

private struct CursorMotionTimingLookup {
    struct Sample {
        let t: CGFloat
        let weightedDistance: CGFloat
    }

    let samples: [Sample]
    let pathLength: CGFloat
    let weightedLength: CGFloat

    static func build(for path: CursorMotionPath) -> CursorMotionTimingLookup {
        let sampleCount = 120
        var samples: [Sample] = [.init(t: 0, weightedDistance: 0)]
        var previous = path.sample(at: 0)
        var previousHeading = atan2(previous.tangent.dy, previous.tangent.dx)
        var pathLength: CGFloat = 0
        var weightedLength: CGFloat = 0

        for index in 1...sampleCount {
            let t = CGFloat(index) / CGFloat(sampleCount)
            let current = path.sample(at: t)
            let ds = hypot(current.point.x - previous.point.x, current.point.y - previous.point.y)
            let heading = atan2(current.tangent.dy, current.tangent.dx)
            let headingChange = abs(normalize(angle: heading - previousHeading))
            let midpoint = (t + samples[index - 1].t) * 0.5
            let curvature = path.curvature(at: midpoint)
            let curvatureWeight = min(curvature * max(path.arcHeight, 48), 1.75)
            let segmentProfile = edgeProfile(at: midpoint)
            let effortMultiplier = 1
                + (headingChange * 1.9)
                + (curvatureWeight * 0.65)
                + (segmentProfile * (0.08 + (headingChange * 0.45)))

            pathLength += ds
            weightedLength += ds * effortMultiplier
            samples.append(.init(t: t, weightedDistance: weightedLength))

            previous = current
            previousHeading = heading
        }

        return CursorMotionTimingLookup(samples: samples, pathLength: pathLength, weightedLength: weightedLength)
    }

    func parameter(at progress: CGFloat) -> CGFloat {
        guard weightedLength > 0, samples.count > 1 else {
            return progress.clamped(to: 0...1)
        }

        let target = progress.clamped(to: 0...1) * weightedLength
        var low = 0
        var high = samples.count - 1

        while low < high {
            let mid = (low + high) / 2
            if samples[mid].weightedDistance < target {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let upperIndex = max(low, 1)
        let upper = samples[upperIndex]
        let lower = samples[upperIndex - 1]
        let span = max(upper.weightedDistance - lower.weightedDistance, 0.001)
        let localProgress = ((target - lower.weightedDistance) / span).clamped(to: 0...1)
        return lower.t + ((upper.t - lower.t) * localProgress)
    }

    private static func edgeProfile(at t: CGFloat) -> CGFloat {
        let startBias = exp(-pow((t - 0.08) / 0.16, 2))
        let endBias = exp(-pow((t - 0.90) / 0.14, 2))
        return max(startBias, endBias)
    }

    private static func normalize(angle: CGFloat) -> CGFloat {
        var value = angle
        while value > .pi {
            value -= 2 * .pi
        }
        while value < -.pi {
            value += 2 * .pi
        }
        return value
    }
}

final class CursorMotionSimulator {
    private(set) var parameters: CursorMotionParameters
    private(set) var path: CursorMotionPath
    private(set) var springParameters: CursorSpringParameters
    private(set) var start: CGPoint
    private(set) var end: CGPoint

    private var timingLookup: CursorMotionTimingLookup
    private var elapsedTime: CGFloat = 0
    private var travelDuration: CGFloat = 0.42
    private var displayedRotation: CGFloat = 0

    init(start: CGPoint, end: CGPoint, parameters: CursorMotionParameters) {
        self.parameters = parameters
        self.start = start
        self.end = end
        self.path = CursorMotionPathBuilder.makePath(from: start, to: end, parameters: parameters)
        self.springParameters = .from(parameters.spring)
        self.timingLookup = CursorMotionTimingLookup.build(for: path)
        self.travelDuration = Self.duration(for: timingLookup, spring: springParameters)
        self.displayedRotation = CursorGlyphCalibration.restingRotation
    }

    func reset(start: CGPoint? = nil, end: CGPoint? = nil, parameters: CursorMotionParameters? = nil) {
        if let parameters {
            self.parameters = parameters
        }
        if let start {
            self.start = start
        }
        if let end {
            self.end = end
        }

        path = CursorMotionPathBuilder.makePath(from: self.start, to: self.end, parameters: self.parameters)
        springParameters = .from(self.parameters.spring)
        timingLookup = CursorMotionTimingLookup.build(for: path)
        travelDuration = Self.duration(for: timingLookup, spring: springParameters)
        elapsedTime = 0
        displayedRotation = CursorGlyphCalibration.restingRotation
    }

    func reset(path: CursorMotionPath, parameters: CursorMotionParameters? = nil) {
        if let parameters {
            self.parameters = parameters
        }
        self.path = path
        self.start = path.start
        self.end = path.end
        springParameters = .from(self.parameters.spring)
        timingLookup = CursorMotionTimingLookup.build(for: path)
        travelDuration = Self.duration(for: timingLookup, spring: springParameters)
        elapsedTime = 0
        displayedRotation = CursorGlyphCalibration.restingRotation
    }

    func step(deltaTime dt: CGFloat) -> CursorMotionState {
        let clampedDelta = max(1.0 / 240.0, min(dt, 1.0 / 24.0))
        elapsedTime += clampedDelta
        let rawProgress = (elapsedTime / max(travelDuration, 0.001)).clamped(to: 0...1)
        let effortProgress = minimumJerk(rawProgress)
        let pathProgress = timingLookup.parameter(at: effortProgress)
        let sample = path.sample(at: pathProgress)
        let point = sample.point
        let liveRotation = rotation(for: sample.tangent)
        let releaseStart = 1 - (springParameters.finishRelaxation * 0.55)
        let releaseBlend = smoothstep(
            from: releaseStart.clamped(to: 0...0.98),
            to: 1,
            value: rawProgress
        )
        let targetRotation = blendAngle(
            from: liveRotation,
            to: CursorGlyphCalibration.restingRotation,
            progress: releaseBlend
        )
        displayedRotation = interpolateAngle(
            from: displayedRotation,
            to: targetRotation,
            maxStep: (0.12 + (springParameters.headingResponse * 0.74)) * (clampedDelta * 60)
        )

        return CursorMotionState(
            point: point,
            rotation: rawProgress >= 1 ? CursorGlyphCalibration.restingRotation : displayedRotation,
            trailProgress: pathProgress,
            isSettled: rawProgress >= 1
        )
    }

    private func rotation(for tangent: CGVector) -> CGFloat {
        guard tangent.dx != 0 || tangent.dy != 0 else {
            return CursorGlyphCalibration.restingRotation
        }
        let heading = atan2(tangent.dy, tangent.dx)
        return normalize(angle: heading - CursorGlyphCalibration.neutralHeading)
    }

    private func normalize(angle: CGFloat) -> CGFloat {
        var value = angle
        while value > .pi {
            value -= 2 * .pi
        }
        while value < -.pi {
            value += 2 * .pi
        }
        return value
    }

    private func minimumJerk(_ value: CGFloat) -> CGFloat {
        let t = value.clamped(to: 0...1)
        return (10 * pow(t, 3)) - (15 * pow(t, 4)) + (6 * pow(t, 5))
    }

    private func smoothstep(from start: CGFloat, to end: CGFloat, value: CGFloat) -> CGFloat {
        guard end > start else {
            return value >= end ? 1 : 0
        }
        let t = ((value - start) / (end - start)).clamped(to: 0...1)
        return t * t * (3 - (2 * t))
    }

    private func interpolateAngle(from current: CGFloat, to target: CGFloat, maxStep: CGFloat) -> CGFloat {
        let delta = normalize(angle: target - current)
        guard abs(delta) > maxStep else {
            return target
        }
        return normalize(angle: current + (delta.sign == .minus ? -maxStep : maxStep))
    }

    private func blendAngle(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
        let clamped = progress.clamped(to: 0...1)
        let delta = normalize(angle: end - start)
        return normalize(angle: start + (delta * clamped))
    }

    private static func duration(for lookup: CursorMotionTimingLookup, spring: CursorSpringParameters) -> CGFloat {
        let distance = max(lookup.pathLength, 1)
        let distanceTerm = 0.18 + min(distance / 1320, 0.34)
        let curvatureTerm = min(max((lookup.weightedLength / distance) - 1, 0), 1.4) * 0.16
        return max((distanceTerm + curvatureTerm) * spring.durationScale, 0.22)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
