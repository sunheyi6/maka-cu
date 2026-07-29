import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ScreenCaptureKit

/// §8 — every image is a file path. There is no size threshold and no inline
/// branch: base64 on a line-delimited channel is a 4/3 blow-up that stalls every
/// other pending response while one 8 MB line is written.
public final class HostImageStore {
    public let directory: URL
    private let budgetBytes: Int
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var counter = 0

    public init(directory: URL, budgetBytes: Int) {
        self.directory = directory
        self.budgetBytes = budgetBytes
    }

    /// §2 — writability is verified during the handshake. Discovering the
    /// directory is read-only at the first `observe` would turn a configuration
    /// error into a capture failure.
    public func verifyWritable() throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HostRPCError.invalidParams("imageDir")
        }

        let probe = directory.appendingPathComponent(".maka-cu-write-probe")
        guard fileManager.createFile(atPath: probe.path, contents: Data([0x6F, 0x6B])) else {
            throw HostRPCError.invalidParams("imageDir")
        }

        try? fileManager.removeItem(at: probe)
    }

    public func delete(path: String) {
        // Only files this store owns may be removed; the host addresses images by
        // the path it was given, and a path from anywhere else is not ours.
        guard URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            return
        }

        try? fileManager.removeItem(atPath: path)
    }

    /// Writes a PNG and returns the reference the wire carries. `scale` is
    /// measured from the image actually captured, never read off
    /// `NSScreen.backingScaleFactor`, because the two disagree on scaled displays
    /// and a wrong scale lands a click a quarter of the way into a control.
    public func writePNG(
        _ image: CGImage,
        namePrefix: String,
        logicalWidth: CGFloat
    ) -> Result<HostImageReference, HostDomainError> {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return .failure(HostDomainError(.imageWriteFailed))
        }

        lock.lock()
        counter += 1
        let name = "\(namePrefix)_\(counter).png"
        lock.unlock()

        let url = directory.appendingPathComponent(name)

        if !makeRoom(for: data.count) {
            return .failure(HostDomainError(.imageWriteFailed))
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return .failure(HostDomainError(.imageWriteFailed))
        }

        return .success(
            HostImageReference(
                path: url.path,
                format: .png,
                widthPx: image.width,
                heightPx: image.height,
                byteLength: data.count,
                sha256: HostDigest.sha256(data),
                scale: logicalWidth > 0 ? Double(image.width) / Double(logicalWidth) : 1
            )
        )
    }

    /// §8 — evict this store's oldest files first; report `image_write_failed`
    /// rather than silently returning a snapshot without the image asked for.
    private func makeRoom(for incoming: Int) -> Bool {
        guard incoming <= budgetBytes else {
            return false
        }

        var entries = ownedFiles()
        var total = entries.reduce(0) { $0 + $1.size }

        while total + incoming > budgetBytes, !entries.isEmpty {
            let oldest = entries.removeFirst()
            try? fileManager.removeItem(at: oldest.url)
            total -= oldest.size
        }

        return total + incoming <= budgetBytes
    }

    private func ownedFiles() -> [(url: URL, size: Int, created: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                    return nil
                }
                return (url, values.fileSize ?? 0, values.creationDate ?? .distantPast)
            }
            .sorted { $0.created < $1.created }
    }
}

public enum HostCapture {
    static let timeout: TimeInterval = 5

    /// Window capture through ScreenCaptureKit. `capture_failed` and `timeout` are
    /// separate results because a timed-out capture means the compositor is busy
    /// and a retry is reasonable, while a failed one usually means the window went
    /// away.
    public static func captureWindow(windowId: CGWindowID, scope: HostCaptureScope) -> Result<CGImage, HostDomainError> {
        do {
            let image = try BlockingAsyncBridge.run(timeout: timeout) {
                let content = try await SCShareableContent.current
                guard let window = content.windows.first(where: { $0.windowID == windowId }) else {
                    return CGImage?.none
                }

                let configuration = SCStreamConfiguration()
                let scale = NSScreen.screens
                    .first(where: { $0.frame.intersects(window.frame) })?
                    .backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
                configuration.width = max(1, Int((window.frame.width * scale).rounded()))
                configuration.height = max(1, Int((window.frame.height * scale).rounded()))
                configuration.showsCursor = false
                configuration.scalesToFit = false
                configuration.ignoreShadowsSingleWindow = true

                let filter: SCContentFilter
                switch scope {
                case .window:
                    filter = SCContentFilter(desktopIndependentWindow: window)
                case .desktop:
                    guard let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) ?? content.displays.first else {
                        return CGImage?.none
                    }
                    filter = SCContentFilter(display: display, excludingWindows: [])
                }

                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            }

            guard let image else {
                return .failure(HostDomainError(.captureFailed))
            }

            return .success(image)
        } catch {
            return .failure(HostDomainError(.timeout))
        }
    }

    public static func captureDisplay(displayId: CGDirectDisplayID) -> Result<CGImage, HostDomainError> {
        do {
            let image = try BlockingAsyncBridge.run(timeout: timeout) {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first(where: { $0.displayID == displayId }) else {
                    return CGImage?.none
                }

                let configuration = SCStreamConfiguration()
                configuration.width = display.width
                configuration.height = display.height
                configuration.showsCursor = false

                return try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: []),
                    configuration: configuration
                )
            }

            guard let image else {
                return .failure(HostDomainError(.captureFailed))
            }

            return .success(image)
        } catch {
            return .failure(HostDomainError(.timeout))
        }
    }
}
