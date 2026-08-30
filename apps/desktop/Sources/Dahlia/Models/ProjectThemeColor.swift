import SwiftUI

enum ProjectThemeColor: String, CaseIterable, Codable, Sendable {
    case neutral
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink

    var color: Color {
        switch self {
        case .neutral: .primary
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        }
    }

    var localizedName: String {
        switch self {
        case .neutral: L10n.projectColorNeutral
        case .red: L10n.projectColorRed
        case .orange: L10n.projectColorOrange
        case .yellow: L10n.projectColorYellow
        case .green: L10n.projectColorGreen
        case .blue: L10n.projectColorBlue
        case .purple: L10n.projectColorPurple
        case .pink: L10n.projectColorPink
        }
    }
}
