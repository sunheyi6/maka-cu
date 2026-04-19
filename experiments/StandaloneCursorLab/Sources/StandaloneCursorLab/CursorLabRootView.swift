import AppKit
import QuartzCore
import SwiftUI

struct CursorLabRootView: View {
    @State private var parameters = CursorMotionParameters.default
    @State private var start = CGPoint(x: 220, y: 440)
    @State private var end = CGPoint(x: 860, y: 260)
    @State private var debugEnabled = true
    @State private var mailEnabled = false
    @State private var clickEnabled = true
    @StateObject private var model = CursorLabViewModel()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                CursorLabBackground()

                CursorLabCanvas(
                    start: $start,
                    end: $end,
                    debugEnabled: debugEnabled,
                    showClickPulse: clickEnabled,
                    model: model
                )
                .onAppear {
                    model.configure(start: start, end: end, parameters: parameters)
                    model.restart()
                }
                .onChange(of: proxy.size) { _, newSize in
                    clampPoints(to: newSize)
                    model.configure(start: start, end: end, parameters: parameters)
                }
                .onChange(of: start) { _, newValue in
                    model.updateStart(newValue)
                }
                .onChange(of: end) { _, newValue in
                    model.queueMove(to: newValue)
                }
                .onChange(of: parameters) { _, newValue in
                    model.updateParameters(newValue)
                }
            }
            .overlay(alignment: .topLeading) {
                controlPanel
                    .padding(24)
            }
            .overlay(alignment: .topTrailing) {
                togglePanel
                    .padding(24)
            }
        }
    }

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            CursorSliderRow(title: "START HANDLE", value: $parameters.startHandle)
            CursorSliderRow(title: "END HANDLE", value: $parameters.endHandle)
            CursorSliderRow(title: "ARC SIZE", value: $parameters.arcSize)
            CursorSliderRow(title: "ARC FLOW", value: $parameters.arcFlow, accent: Color(red: 0.92, green: 0.22, blue: 0.58))
            CursorSliderRow(title: "SPRING", value: $parameters.spring)

            Button("REPLAY") {
                model.replayCurrentSelection()
            }
            .buttonStyle(CursorActionButtonStyle())
            .padding(.top, 6)
        }
    }

    private var togglePanel: some View {
        VStack(alignment: .trailing, spacing: 12) {
            CursorToggleRow(title: "DEBUG", isOn: $debugEnabled)
            CursorToggleRow(title: "MAIL", isOn: $mailEnabled)
            CursorToggleRow(title: "CLICK", isOn: $clickEnabled)
        }
    }

    private func clampPoints(to size: CGSize) {
        let inset: CGFloat = 80
        start.x = min(max(start.x, inset), size.width - inset)
        start.y = min(max(start.y, inset), size.height - inset)
        end.x = min(max(end.x, inset), size.width - inset)
        end.y = min(max(end.y, inset), size.height - inset)
    }
}

@MainActor
final class CursorLabViewModel: ObservableObject {
    @Published private(set) var path = CursorMotionPathBuilder.makePath(
        from: CGPoint(x: 220, y: 440),
        to: CGPoint(x: 860, y: 260),
        parameters: .default
    )
    @Published private(set) var candidates: [CursorMotionCandidate] = []
    @Published private(set) var selectedCandidateID: String?
    @Published private(set) var currentState = CursorMotionState(
        point: CGPoint(x: 220, y: 440),
        rotation: CursorGlyphCalibration.restingRotation,
        trailProgress: 0,
        isSettled: false
    )
    @Published private(set) var clickPulse: CGFloat = 0

    private var simulator = CursorMotionSimulator(
        start: CGPoint(x: 220, y: 440),
        end: CGPoint(x: 860, y: 260),
        parameters: .default
    )
    private var displayLink: CVDisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var previewRemaining: CGFloat = 0
    private var queuedTarget: CGPoint?

    func configure(start: CGPoint, end: CGPoint, parameters: CursorMotionParameters) {
        simulator.reset(start: start, end: end, parameters: parameters)
        path = simulator.path
        candidates = CursorMotionPathBuilder.makeCandidatePaths(
            from: start,
            to: end,
            parameters: parameters,
            startRotation: currentState.rotation
        )
        selectedCandidateID = candidates.first?.id
        currentState = CursorMotionState(point: start, rotation: CursorGlyphCalibration.restingRotation, trailProgress: 0, isSettled: false)
        clickPulse = 0
    }

    func updateStart(_ value: CGPoint) {
        simulator.reset(start: value)
        path = simulator.path
        candidates = CursorMotionPathBuilder.makeCandidatePaths(
            from: value,
            to: simulator.end,
            parameters: simulator.parameters,
            startRotation: currentState.rotation
        )
        selectedCandidateID = candidates.first?.id
        currentState = CursorMotionState(point: value, rotation: currentState.rotation, trailProgress: 0, isSettled: false)
    }

    func queueMove(to value: CGPoint) {
        queuedTarget = value
        let origin = currentAnchorPoint
        let startRotation = currentState.rotation
        candidates = CursorMotionPathBuilder.makeCandidatePaths(
            from: origin,
            to: value,
            parameters: simulator.parameters,
            startRotation: startRotation
        )
        selectedCandidateID = candidates.first?.id
        path = candidates.first?.path ?? CursorMotionPathBuilder.makePath(
            from: origin,
            to: value,
            parameters: simulator.parameters,
            startRotation: startRotation
        )
        currentState = CursorMotionState(point: origin, rotation: currentState.rotation, trailProgress: 0, isSettled: false)
        clickPulse = 0
        previewRemaining = 0.24
        lastTimestamp = nil
        ensureDisplayLink()
    }

    func updateParameters(_ value: CursorMotionParameters) {
        simulator.reset(parameters: value)
        if let queuedTarget {
            queueMove(to: queuedTarget)
        } else {
            candidates = CursorMotionPathBuilder.makeCandidatePaths(
                from: currentAnchorPoint,
                to: simulator.end,
                parameters: value,
                startRotation: currentState.rotation
            )
            selectedCandidateID = candidates.first?.id
            path = candidates.first?.path ?? simulator.path
            currentState = CursorMotionState(point: currentAnchorPoint, rotation: currentState.rotation, trailProgress: 0, isSettled: false)
            clickPulse = 0
        }
    }

    func restart() {
        replayCurrentSelection()
    }

    func replayCurrentSelection() {
        let target = queuedTarget ?? simulator.end
        queueMove(to: target)
    }

    private func ensureDisplayLink() {
        guard displayLink == nil else {
            return
        }

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else {
            return
        }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
            guard let userInfo else {
                return kCVReturnSuccess
            }

            let viewModel = Unmanaged<CursorLabViewModel>.fromOpaque(userInfo).takeUnretainedValue()
            Task { @MainActor in
                viewModel.tick()
            }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        displayLink = link
        CVDisplayLinkStart(link)
    }

    private func stop() {
        guard let displayLink else {
            return
        }
        CVDisplayLinkStop(displayLink)
        self.displayLink = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(lastTimestamp.map { now - $0 } ?? (1.0 / 60.0))
        lastTimestamp = now

        if previewRemaining > 0 {
            previewRemaining -= dt
            if previewRemaining <= 0 {
                startSelectedCandidateAnimation()
            }
            return
        }

        currentState = simulator.step(deltaTime: dt)
        path = simulator.path

        if currentState.trailProgress > 0.94 {
            let pulseProgress = min(max((currentState.trailProgress - 0.94) / 0.06, 0), 1)
            clickPulse = sin(pulseProgress * .pi)
        } else {
            clickPulse = 0
        }

        if currentState.isSettled {
            stop()
        }
    }

    private func startSelectedCandidateAnimation() {
        guard let selectedPath = candidates.first(where: { $0.id == selectedCandidateID })?.path ?? candidates.first?.path else {
            stop()
            return
        }

        simulator.reset(path: selectedPath)
        path = selectedPath
        currentState = CursorMotionState(point: selectedPath.start, rotation: CursorGlyphCalibration.restingRotation, trailProgress: 0, isSettled: false)
    }

    private var currentAnchorPoint: CGPoint {
        if previewRemaining > 0 {
            return currentState.point
        }
        return currentState.isSettled ? simulator.end : currentState.point
    }
}

private struct CursorLabCanvas: View {
    @Binding var start: CGPoint
    @Binding var end: CGPoint
    let debugEnabled: Bool
    let showClickPulse: Bool
    @ObservedObject var model: CursorLabViewModel

    var body: some View {
        ZStack {
            persistentPathLayer

            if debugEnabled {
                debugCandidateLayer
            }

            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 8))
                .position(start)
                .allowsHitTesting(false)

            Circle()
                .fill(Color(red: 0.98, green: 0.45, blue: 0.68))
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 8))
                .position(end)
                .allowsHitTesting(false)

            CursorGlyph(rotation: model.currentState.rotation, clickPulse: showClickPulse ? model.clickPulse : 0)
                .position(model.currentState.point)
                .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 4)
                .allowsHitTesting(false)

            CanvasClickCapture { location in
                end = location
            }
        }
    }

    private var persistentPathLayer: some View {
        Canvas { context, _ in
            let selectedPath = Path(model.path.cgPath)
            context.stroke(
                selectedPath,
                with: .linearGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.28),
                        Color(red: 0.98, green: 0.72, blue: 0.86).opacity(0.16),
                    ]),
                    startPoint: model.path.start,
                    endPoint: model.path.end
                ),
                style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
            )

            let livePath = trimmedPath(progress: model.currentState.trailProgress)
            context.stroke(
                livePath,
                with: .linearGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.88),
                        Color(red: 0.97, green: 0.38, blue: 0.65).opacity(0.95),
                    ]),
                    startPoint: model.path.start,
                    endPoint: model.path.end
                ),
                style: StrokeStyle(lineWidth: 5.2, lineCap: .round, lineJoin: .round)
            )
        }
        .allowsHitTesting(false)
    }

    private var debugCandidateLayer: some View {
        Canvas { context, _ in
            for (index, candidate) in model.candidates.enumerated() where candidate.id != model.selectedCandidateID {
                let path = Path(candidate.path.cgPath)
                let strokeColor = Color.white.opacity(max(0.10, 0.22 - CGFloat(index) * 0.016))
                context.stroke(
                    path,
                    with: .color(strokeColor),
                    style: StrokeStyle(lineWidth: 1.25, dash: [6, 8], dashPhase: CGFloat(index) * 2)
                )
            }

            let handleStroke = StrokeStyle(lineWidth: 1.0, dash: [4, 6])
            let handleColor = Color.white.opacity(0.22)
            context.stroke(Path { path in
                path.move(to: model.path.start)
                path.addLine(to: model.path.control1)
                path.move(to: model.path.end)
                path.addLine(to: model.path.control2)
            }, with: .color(handleColor), style: handleStroke)

            for point in [model.path.control1, model.path.control2] {
                let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.55)))
            }

            if let selectedCandidate = model.candidates.first(where: { $0.id == model.selectedCandidateID }) {
                let labelPoint = CGPoint(
                    x: selectedCandidate.path.point(at: 0.54).x + 18,
                    y: selectedCandidate.path.point(at: 0.54).y - 16
                )
                let text = Text("SELECTED")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundColor(.white.opacity(0.82))
                context.draw(text, at: labelPoint, anchor: .leading)
            }
        }
        .allowsHitTesting(false)
    }

    private func trimmedPath(progress: CGFloat) -> Path {
        Path(model.path.cgPath).trimmedPath(from: 0, to: max(0.001, min(progress, 1)))
    }
}

private struct CanvasClickCapture: NSViewRepresentable {
    let onTap: (CGPoint) -> Void

    func makeNSView(context: Context) -> ClickCaptureView {
        let view = ClickCaptureView()
        view.onTap = onTap
        return view
    }

    func updateNSView(_ nsView: ClickCaptureView, context: Context) {
        nsView.onTap = onTap
    }
}

private final class ClickCaptureView: NSView {
    var onTap: ((CGPoint) -> Void)?

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onTap?(location)
    }
}

private struct CursorGlyph: View {
    let rotation: CGFloat
    let clickPulse: CGFloat

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.12))
                .frame(width: 22 + clickPulse * 4, height: 6 + clickPulse * 1.4)
                .offset(x: 0, y: 24)
                .blur(radius: 1.6)

            glyphBody

            if clickPulse > 0.02 {
                Circle()
                    .stroke(Color.white.opacity(0.26), lineWidth: 1)
                    .frame(width: 8 + clickPulse * 12, height: 8 + clickPulse * 12)
            }
        }
        .frame(width: CursorGlyphArtwork.layoutSize.width, height: CursorGlyphArtwork.layoutSize.height)
        .rotationEffect(.radians(rotation), anchor: .center)
        .scaleEffect(x: 1 - clickPulse * 0.04, y: 1 + clickPulse * 0.03, anchor: .center)
    }

    @ViewBuilder
    private var glyphBody: some View {
        if let image = CursorGlyphArtwork.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .frame(width: CursorGlyphArtwork.imageSize.width, height: CursorGlyphArtwork.imageSize.height)
                .offset(CursorGlyphArtwork.contentOffset)
        } else {
            CursorGlyphFallbackShape()
                .fill(Color.black.opacity(0.92))
                .frame(width: CursorGlyphArtwork.imageSize.width, height: CursorGlyphArtwork.imageSize.height)
                .offset(CursorGlyphArtwork.contentOffset)
        }
    }
}

private struct CursorGlyphFallbackShape: Shape {
    func path(in rect: CGRect) -> Path {
        return Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY * 0.86),
                control: CGPoint(x: rect.maxX * 0.92, y: rect.maxY * 0.28)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.midX, y: rect.maxY * 0.62),
                control: CGPoint(x: rect.maxX * 0.82, y: rect.maxY * 1.02)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY * 0.86),
                control: CGPoint(x: rect.maxX * 0.18, y: rect.maxY * 1.02)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.midX, y: rect.minY),
                control: CGPoint(x: rect.maxX * 0.08, y: rect.maxY * 0.28)
            )
            path.closeSubpath()
        }
    }
}

private struct CursorSliderRow: View {
    let title: String
    @Binding var value: CGFloat
    var accent: Color = Color(red: 0.94, green: 0.28, blue: 0.62)

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: Binding(
                get: { Double(value) },
                set: { value = CGFloat($0) }
            ), in: 0...1)
            .tint(accent)
            .frame(width: 66)

            Text(title)
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.82))
                .tracking(0.8)
                .frame(width: 92, alignment: .leading)
        }
    }
}

private struct CursorToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var accent: Color = Color(red: 0.92, green: 0.22, blue: 0.58)

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.82))
                .tracking(0.8)

            Toggle("", isOn: $isOn)
                .toggleStyle(CursorToggleStyle(accent: accent))
                .labelsHidden()
        }
    }
}

private struct CursorToggleStyle: ToggleStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(configuration.isOn ? accent : Color.white.opacity(0.34))
            .frame(width: 38, height: 20)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 15, height: 15)
                    .padding(2)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                configuration.isOn.toggle()
            }
    }
}

private struct CursorActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0.12))
            .foregroundStyle(Color.white.opacity(0.88))
            .clipShape(Capsule())
    }
}

private struct CursorLabBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.96, green: 0.75, blue: 0.85),
                Color(red: 0.92, green: 0.71, blue: 0.91),
                Color(red: 0.97, green: 0.62, blue: 0.76),
                Color(red: 0.44, green: 0.77, blue: 0.97),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Canvas { context, size in
                let blobs: [(CGPoint, CGSize, Color)] = [
                    (CGPoint(x: size.width * 0.18, y: size.height * 0.20), CGSize(width: 360, height: 620), Color.white.opacity(0.20)),
                    (CGPoint(x: size.width * 0.55, y: size.height * 0.58), CGSize(width: 420, height: 720), Color(red: 1, green: 0.72, blue: 0.82).opacity(0.22)),
                    (CGPoint(x: size.width * 0.82, y: size.height * 0.26), CGSize(width: 360, height: 520), Color(red: 0.52, green: 0.82, blue: 1).opacity(0.26)),
                ]

                for blob in blobs {
                    let rect = CGRect(origin: .zero, size: blob.1).offsetBy(dx: blob.0.x - blob.1.width / 2, dy: blob.0.y - blob.1.height / 2)
                    context.addFilter(.blur(radius: 48))
                    context.fill(Path(ellipseIn: rect), with: .color(blob.2))
                }
            }
        }
        .ignoresSafeArea()
    }
}
