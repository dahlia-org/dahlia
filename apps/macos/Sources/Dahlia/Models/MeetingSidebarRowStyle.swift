import Foundation

enum MeetingSidebarRowStyle: String, CaseIterable, Identifiable, Sendable {
    case standard
    case compact

    var id: Self { self }

    static func resolved(rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .standard
    }

    var label: String {
        switch self {
        case .standard: L10n.standard
        case .compact: L10n.compact
        }
    }
}
