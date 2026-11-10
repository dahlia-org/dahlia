/// The sidebar menu button the user picked; it decides what the sidebar lists.
enum MainSidebarTab: CaseIterable {
    case home
    case meetings
    case projects
    case chat

    var title: String {
        switch self {
        case .home: L10n.home
        case .meetings: L10n.meetings
        case .projects: L10n.projects
        case .chat: L10n.chat
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .meetings: "calendar"
        case .projects: "folder"
        case .chat: "bubble.left"
        }
    }

    var shortcutKey: Character {
        switch self {
        case .home: "1"
        case .meetings: "2"
        case .projects: "3"
        case .chat: "4"
        }
    }
}
