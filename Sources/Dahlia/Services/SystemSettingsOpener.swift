import AppKit

@MainActor
protocol SystemSettingsOpening {
    func openSettings(for permission: AppPermission) -> Bool
}

@MainActor
struct SystemSettingsOpener: SystemSettingsOpening {
    func openSettings(for permission: AppPermission) -> Bool {
        let workspace = NSWorkspace.shared
        for url in Self.urls(for: permission) where workspace.open(url) {
            return true
        }
        return false
    }

    static func urls(for permission: AppPermission) -> [URL] {
        let anchor = switch permission {
        case .screenAndSystemAudio:
            "Privacy_ScreenCapture"
        case .microphone:
            "Privacy_Microphone"
        case .calendar:
            "Privacy_Calendars"
        }
        return [
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"),
            URL(string: "x-apple.systempreferences:com.apple.preference.security"),
        ].compactMap(\.self)
    }
}
