import AppKit

/// An app-wide preference stored on this Mac and shared by all accounts and windows.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let userDefaultsKey = "appAppearance"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: L10n.followSystem
        case .light: L10n.lightMode
        case .dark: L10n.darkMode
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
