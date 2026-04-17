import ApplicationServices
import AppKit
import Foundation
import SQLite3

public enum SystemPermissionKind: String, CaseIterable, Sendable {
    case accessibility
    case screenRecording

    public var title: String {
        switch self {
        case .accessibility:
            return "Accessibility"
        case .screenRecording:
            return "Screenshots"
        }
    }

    public var subtitle: String {
        switch self {
        case .accessibility:
            return "Allows Open Computer Use to access app interfaces"
        case .screenRecording:
            return "Open Computer Use uses screenshots to know where to click"
        }
    }

    public var settingsURL: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }

    public var dragInstruction: String {
        switch self {
        case .accessibility:
            return "Drag Open Computer Use above to allow Accessibility"
        case .screenRecording:
            return "Drag Open Computer Use above to allow Screenshots"
        }
    }

    public var systemSettingsTitle: String {
        switch self {
        case .accessibility:
            return "Accessibility"
        case .screenRecording:
            return "Screen & System Audio Recording"
        }
    }

    public var symbolName: String {
        switch self {
        case .accessibility:
            return "figure.arms.open"
        case .screenRecording:
            return "camera.viewfinder"
        }
    }
}

public struct PermissionDiagnostics: Sendable {
    public let accessibilityTrusted: Bool
    public let screenCaptureGranted: Bool

    public static func current() -> PermissionDiagnostics {
        let persisted = TCCAuthorizationStore.current

        return PermissionDiagnostics(
            accessibilityTrusted: persisted.accessibility ?? AXIsProcessTrusted(),
            screenCaptureGranted: persisted.screenRecording ?? CGPreflightScreenCaptureAccess()
        )
    }

    public var summary: String {
        "Permissions: accessibility=\(accessibilityTrusted ? "granted" : "missing"), screenRecording=\(screenCaptureGranted ? "granted" : "missing")"
    }

    public var missingPermissions: [SystemPermissionKind] {
        SystemPermissionKind.allCases.filter { !isGranted($0) }
    }

    public func isGranted(_ permission: SystemPermissionKind) -> Bool {
        switch permission {
        case .accessibility:
            return accessibilityTrusted
        case .screenRecording:
            return screenCaptureGranted
        }
    }

    public var allGranted: Bool {
        accessibilityTrusted && screenCaptureGranted
    }
}

public enum PermissionSupport {
    public static let bundleDisplayName = "Open Computer Use"
    public static let bundleIdentifier = "com.ifuryst.opencomputeruse"
    private static let npmPackageNames = [
        "open-computer-use",
        "open-computer-use-mcp",
        "open-codex-computer-use-mcp",
    ]

    public static func currentAppBundleURL() -> URL? {
        if let bundleURL = resolvedMainAppBundleURL() {
            return bundleURL
        }

        return preferredInstalledAppBundleURL() ?? fallbackDevelopmentAppBundleURL()
    }

    public static func currentPermissionClients() -> [PermissionClientRecord] {
        var records: [PermissionClientRecord] = []

        if let bundleURL = currentAppBundleURL()?.standardizedFileURL {
            records.append(PermissionClientRecord(identifier: bundleURL.path, type: 1))

            if let bundle = Bundle(url: bundleURL),
               let resolvedBundleIdentifier = bundle.bundleIdentifier {
                records.append(PermissionClientRecord(identifier: resolvedBundleIdentifier, type: 0))
            }
        } else if let mainBundleIdentifier = Bundle.main.bundleIdentifier {
            records.append(PermissionClientRecord(identifier: mainBundleIdentifier, type: 0))
        }

        if !records.contains(where: { $0.identifier == bundleIdentifier && $0.type == 0 }) {
            records.append(PermissionClientRecord(identifier: bundleIdentifier, type: 0))
        }

        return records
    }

    public static func openSystemSettings(for permission: SystemPermissionKind) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    public static func requestAccessibilityPrompt() {
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func preferredInstalledAppBundleURL() -> URL? {
        for nodeModulesRoot in npmGlobalNodeModulesRoots() {
            for packageName in npmPackageNames {
                let candidate = nodeModulesRoot
                    .appendingPathComponent(packageName, isDirectory: true)
                    .appendingPathComponent("dist", isDirectory: true)
                    .appendingPathComponent("\(bundleDisplayName).app", isDirectory: true)

                if isValidAppBundle(candidate) {
                    return candidate
                }
            }
        }

        return nil
    }

    private static func fallbackDevelopmentAppBundleURL() -> URL? {
        guard let executableURL = Bundle.main.executableURL?.standardizedFileURL else {
            return nil
        }

        var directoryURL = executableURL.deletingLastPathComponent()

        while directoryURL.path != "/" {
            let candidate = directoryURL
                .appendingPathComponent("dist", isDirectory: true)
                .appendingPathComponent("\(bundleDisplayName).app", isDirectory: true)

            if isValidAppBundle(candidate) {
                return candidate
            }

            let parentURL = directoryURL.deletingLastPathComponent()
            if parentURL == directoryURL {
                break
            }
            directoryURL = parentURL
        }

        return nil
    }

    private static func npmGlobalNodeModulesRoots() -> [URL] {
        let env = ProcessInfo.processInfo.environment
        let candidatePrefixes = [
            env["npm_config_prefix"],
            env["NPM_CONFIG_PREFIX"],
            env["PREFIX"],
            NSHomeDirectory() + "/.npm-global",
            "/opt/homebrew",
            "/usr/local",
        ]
        .compactMap { $0 }
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

        var roots: [URL] = []
        var seenPaths = Set<String>()

        for prefix in candidatePrefixes {
            let root = prefix.appendingPathComponent("lib", isDirectory: true)
                .appendingPathComponent("node_modules", isDirectory: true)
                .standardizedFileURL

            if seenPaths.insert(root.path).inserted {
                roots.append(root)
            }
        }

        return roots
    }

    private static func resolvedMainAppBundleURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        guard bundleURL.pathExtension == "app", isValidAppBundle(bundleURL) else {
            return nil
        }

        return bundleURL
    }

    private static func isValidAppBundle(_ bundleURL: URL) -> Bool {
        let fileManager = FileManager.default
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard fileManager.fileExists(atPath: infoPlistURL.path),
              let bundle = Bundle(url: bundleURL),
              let executableName = bundle.object(forInfoDictionaryKey: kCFBundleExecutableKey as String) as? String,
              !executableName.isEmpty,
              bundle.bundleIdentifier == bundleIdentifier
        else {
            return false
        }

        let executableURL = bundleURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        return fileManager.fileExists(atPath: executableURL.path)
    }
}

public struct PermissionClientRecord: Sendable, Equatable {
    public let identifier: String
    public let type: Int32
}

private struct TCCAuthorizationStore {
    let accessibility: Bool?
    let screenRecording: Bool?

    static var current: TCCAuthorizationStore {
        let database = TCCDatabase(path: "/Library/Application Support/com.apple.TCC/TCC.db")
        let clients = PermissionSupport.currentPermissionClients()
        return TCCAuthorizationStore(
            accessibility: database.authorization(for: .accessibility, clients: clients),
            screenRecording: database.authorization(for: .screenRecording, clients: clients)
        )
    }
}

private struct TCCDatabase {
    enum Service: String {
        case accessibility = "kTCCServiceAccessibility"
        case screenRecording = "kTCCServiceScreenCapture"
    }

    private let path: String
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) {
        self.path = path
    }

    func authorization(for service: Service, clients: [PermissionClientRecord]) -> Bool? {
        guard !clients.isEmpty else {
            return nil
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if database != nil {
                sqlite3_close(database)
            }
            return nil
        }
        defer { sqlite3_close(database) }

        let query = """
        SELECT auth_value
        FROM access
        WHERE service = ? AND client = ? AND client_type = ?
        ORDER BY last_modified DESC
        LIMIT 1;
        """

        for client in clients {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
                if statement != nil {
                    sqlite3_finalize(statement)
                }
                return nil
            }

            sqlite3_bind_text(statement, 1, service.rawValue, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, client.identifier, -1, sqliteTransient)
            sqlite3_bind_int(statement, 3, client.type)

            if sqlite3_step(statement) == SQLITE_ROW {
                let authorized = sqlite3_column_int(statement, 0) == 2
                sqlite3_finalize(statement)
                return authorized
            }

            sqlite3_finalize(statement)
        }

        return false
    }
}
