/// The sidebar menu button the user picked; it decides what the sidebar lists.
enum MainSidebarTab: CaseIterable {
    case meetings
    case projects
    case chat

    var title: String {
        switch self {
        case .meetings: L10n.meetings
        case .projects: L10n.projects
        case .chat: L10n.chat
        }
    }

    var systemImage: String {
        switch self {
        case .meetings: "calendar"
        case .projects: "folder"
        case .chat: "message"
        }
    }

    var shortcutKey: Character {
        switch self {
        case .meetings: "1"
        case .projects: "2"
        case .chat: "3"
        }
    }
}
