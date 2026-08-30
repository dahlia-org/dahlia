import AppKit

@MainActor
protocol SystemSettingsOpening {
    func openSettings(for permission: AppPermission) -> Bool
}

@MainActor
struct SystemSettingsOpener: SystemSettingsOpening {
    func openSettings(for permission: AppPermission) -> Bool {
        openFirstAvailable(Self.urls(for: permission))
    }

    func openSoundInputSettings() -> Bool {
        openFirstAvailable(Self.soundInputURLs)
    }

    private func openFirstAvailable(_ urls: [URL]) -> Bool {
        let workspace = NSWorkspace.shared
        for url in urls where workspace.open(url) {
            return true
        }
        return false
    }

    static let soundInputURLs = [
        URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input"),
        URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension"),
    ].compactMap(\.self)

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
