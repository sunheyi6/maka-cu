import AppKit
import CoreGraphics
import Foundation
import SoftwareCursorGlyphKit

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

        drawProceduralGlyph(in: context)
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
