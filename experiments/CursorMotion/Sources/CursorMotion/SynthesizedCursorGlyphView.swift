import AppKit
import CoreGraphics
import Foundation
import OpenComputerUseKit

@MainActor
final class SynthesizedCursorGlyphView: NSView {
    var rotation: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    var cursorBodyOffset: CGVector = .zero {
        didSet { needsDisplay = true }
    }

    var fogOffset: CGVector = .zero {
        didSet { needsDisplay = true }
    }

    var fogOpacity: CGFloat = 0.12 {
        didSet { needsDisplay = true }
    }

    var fogScale: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    var clickProgress: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    private let referenceImage = loadReferenceCursorWindowImage()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.clear.setFill()
        dirtyRect.fill()

        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        if let referenceImage {
            drawReferenceImage(referenceImage, in: context)
            return
        }

        drawProceduralGlyph(in: context)
    }

    private func drawReferenceImage(_ image: NSImage, in context: CGContext) {
        let drawingBodyOffset = drawingVector(from: cursorBodyOffset)
        let motionCompression = min(hypot(cursorBodyOffset.dx, cursorBodyOffset.dy) * 0.008, 0.018)
        let pulseCompression = clickProgress * 0.03

        context.saveGState()
        context.translateBy(
            x: bounds.midX + drawingBodyOffset.dx,
            y: bounds.midY + drawingBodyOffset.dy
        )
        context.rotate(by: drawingAngle(from: rotation - CursorGlyphCalibration.restingRotation))
        context.scaleBy(
            x: 1 - motionCompression - pulseCompression,
            y: 1 + (pulseCompression * 0.4)
        )
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        context.restoreGState()
    }

    private func drawProceduralGlyph(in context: CGContext) {
        SoftwareCursorGlyphRenderer.draw(
            in: bounds,
            context: context,
            state: SoftwareCursorGlyphRenderState(
                rotation: drawingAngle(from: rotation - CursorGlyphCalibration.restingRotation),
                cursorBodyOffset: drawingVector(from: cursorBodyOffset),
                fogOffset: drawingVector(from: fogOffset),
                fogOpacity: fogOpacity,
                fogScale: fogScale,
                clickProgress: clickProgress
            )
        )
    }

    private func drawingVector(from screenVector: CGVector) -> CGVector {
        CGVector(dx: screenVector.dx, dy: -screenVector.dy)
    }

    private func drawingAngle(from screenAngle: CGFloat) -> CGFloat {
        -screenAngle
    }
}

private func loadReferenceCursorWindowImage() -> NSImage? {
    if let bundledReference = Bundle.main.url(
        forResource: "official-software-cursor-window-252",
        withExtension: "png"
    ), let image = NSImage(contentsOf: bundledReference) {
        return image
    }

    let fileURL = URL(fileURLWithPath: #filePath).standardizedFileURL
    let repoRoot = fileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let referenceURL = repoRoot
        .appendingPathComponent("docs/references/codex-computer-use-reverse-engineering/assets/extracted-2026-04-19/official-software-cursor-window-252.png")

    return NSImage(contentsOf: referenceURL)
}
