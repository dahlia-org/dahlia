import Foundation

enum ProjectIcon: String, CaseIterable, Codable, Sendable {
    case folder
    case finance = "dollarsign.circle"
    case book = "book.closed"
    case education = "graduationcap"
    case writing = "pencil"
    case tag
    case code = "curlybraces"
    case terminal
    case music = "music.note"
    case film
    case art = "paintpalette"
    case health = "cross.case"
    case puzzle = "puzzlepiece"
    case nature = "leaf"
    case work = "briefcase"
    case analytics = "chart.bar"

    var localizedName: String {
        switch self {
        case .folder: L10n.projectIconFolder
        case .finance: L10n.projectIconFinance
        case .book: L10n.projectIconBook
        case .education: L10n.projectIconEducation
        case .writing: L10n.projectIconWriting
        case .tag: L10n.tag
        case .code: L10n.projectIconCode
        case .terminal: L10n.projectIconTerminal
        case .music: L10n.projectIconMusic
        case .film: L10n.projectIconFilm
        case .art: L10n.projectIconArt
        case .health: L10n.projectIconHealth
        case .puzzle: L10n.projectIconPuzzle
        case .nature: L10n.projectIconNature
        case .work: L10n.projectIconWork
        case .analytics: L10n.projectIconAnalytics
        }
    }
}
