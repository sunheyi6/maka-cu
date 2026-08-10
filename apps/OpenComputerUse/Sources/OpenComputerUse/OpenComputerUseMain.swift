import AppKit
import Darwin
import Foundation
import OpenComputerUseKit

@main
enum OpenComputerUseMain {
    @MainActor
    static func main() {
        do {
            try run()
        } catch let error as OpenComputerUseCLIError {
            writeToStandardError(error.errorDescription ?? error.message)
            exit(EXIT_FAILURE)
        } catch let error as ComputerUseError {
            writeToStandardError(error.errorDescription ?? String(describing: error))
            exit(EXIT_FAILURE)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            writeToStandardError(message)
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func run() throws {
        // §11 — the host spawns the executor as a direct child, because macOS
        // attributes TCC grants through the responsibility chain and a helper
        // relaunched through LaunchServices gets its own attribution and its own
        // prompts. Nothing here re-launches the process.
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = try parseOpenComputerUseCLI(arguments: arguments)

        switch command {
        case .host:
            let server = HostProtocolServer()
            server.run()
            if server.exitStatus != 0 {
                exit(server.exitStatus)
            }
        case let .doctor(format, launchOnboarding):
            let report = DoctorDiagnostics.current()
            switch format {
            case .text:
                print(report.renderedText)
            case .json:
                print(try report.encodedJSON())
            }
            if launchOnboarding && !report.permissions.allGranted {
                PermissionOnboardingApp.launch()
            }
        case .listApps:
            let service = ComputerUseService()
            print(service.listApps())
        case let .snapshot(app, textLimit, treeLimits):
            let service = ComputerUseService()
            print(try service.getAppState(app: app, textLimit: textLimit, treeLimits: treeLimits).renderedText)
        case .turnEnded:
            postOpenComputerUseTurnEndedNotification()
            print("turn-ended acknowledged")
        case let .help(command):
            print(openComputerUseHelpText(command: command))
        case .version:
            print(resolvedOpenComputerUseVersion())
        case .launchOnboarding:
            if !PermissionDiagnostics.current().allGranted {
                PermissionOnboardingApp.launch()
            }
        }
    }

    private static func writeToStandardError(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else {
            return
        }

        FileHandle.standardError.write(data)
    }
}
