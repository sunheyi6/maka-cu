import AppKit
import CoreGraphics

enum CursorGlyphCalibration {
    static let neutralHeading = -CGFloat.pi / 2
    static let restingRotation = -26.5 * CGFloat.pi / 180
}

enum CursorGlyphArtwork {
    static let layoutSize = CGSize(width: 72, height: 72)
    static let imageSize = CGSize(width: 34, height: 34)
    static let imageOrigin = CGPoint(
        x: (layoutSize.width - imageSize.width) * 0.5,
        y: 8
    )
    static let tipAnchor = CGPoint(
        x: imageOrigin.x + (imageSize.width * 0.5),
        y: imageOrigin.y + 1
    )
    static let contentOffset = CGSize(
        width: (layoutSize.width * 0.5) - tipAnchor.x,
        height: (layoutSize.height * 0.5) - tipAnchor.y
    )

    static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "StandaloneCursorPointer", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}
