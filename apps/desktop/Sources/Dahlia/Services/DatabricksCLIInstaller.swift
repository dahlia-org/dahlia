import AppKit

enum DatabricksCLIInstallationResult: Equatable {
    case started
    case commandCopied
    case failed
}

@MainActor
protocol DatabricksCLIInstalling {
    func installInTerminal() -> DatabricksCLIInstallationResult
}

@MainActor
struct DatabricksCLIInstaller: DatabricksCLIInstalling {
    static let command = "brew install databricks/tap/databricks"

    func installInTerminal() -> DatabricksCLIInstallationResult {
        let source = """
        tell application "Terminal"
            activate
            do script "\(Self.command)"
        end tell
        """
        var error: NSDictionary?
        if NSAppleScript(source: source)?.executeAndReturnError(&error) != nil, error == nil {
            return .started
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(Self.command, forType: .string),
              let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal"),
              NSWorkspace.shared.open(terminalURL)
        else {
            return .failed
        }
        return .commandCopied
    }
}
