import Foundation

struct ProjectAppearance: Codable, Equatable, Sendable {
    static let `default` = ProjectAppearance(icon: .folder, color: .neutral)

    var icon: ProjectIcon
    var color: ProjectThemeColor

    init(icon: ProjectIcon, color: ProjectThemeColor) {
        self.icon = icon
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let icon = try? container.decode(ProjectIcon.self, forKey: .icon),
              let color = try? container.decode(ProjectThemeColor.self, forKey: .color) else {
            self = .default
            return
        }
        self.init(icon: icon, color: color)
    }
}
