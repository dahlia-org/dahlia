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
    case entertainment = "popcorn"
    case painting = "paintbrush"
    case art = "paintpalette"
    case medical = "stethoscope"
    case spark = "asterisk"
    case wellness = "camera.macro"
    case work = "briefcase"
    case analytics = "chart.bar"
    case award = "medal"
    case fitness = "dumbbell"
    case notes = "notebook"
    case balance = "scales"
    case globalWorkspace = "globe.desk"
    case travel = "airplane"
    case global = "globe"
    case tools = "wrench"
    case animals = "pawprint"
    case science = "flask"
    case ideas = "brain"
    case favorite = "heart"
    case plant = "pottedplant"

    // Legacy values remain decodable for existing local appearance preferences.
    case film
    case health = "cross.case"
    case puzzle = "puzzlepiece"
    case nature = "leaf"

    static let allCases: [ProjectIcon] = [
        .folder, .finance, .book, .education, .writing, .tag,
        .code, .terminal, .music, .entertainment, .painting, .art,
        .medical, .spark, .wellness, .work, .analytics, .award,
        .fitness, .notes, .balance, .globalWorkspace, .travel, .global,
        .tools, .animals, .science, .ideas, .favorite, .plant,
    ]

    var systemImageName: String {
        switch self {
        case .notes: "note.text"
        case .balance: "scalemass"
        case .plant: "leaf"
        default: rawValue
        }
    }

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
        case .entertainment, .film: L10n.projectIconFilm
        case .painting, .art: L10n.projectIconArt
        case .medical, .health: L10n.projectIconHealth
        case .spark, .puzzle: L10n.projectIconPuzzle
        case .wellness, .nature, .plant: L10n.projectIconNature
        case .work: L10n.projectIconWork
        case .analytics: L10n.projectIconAnalytics
        case .award: L10n.projectIconAward
        case .fitness: L10n.projectIconFitness
        case .notes: L10n.projectIconNotes
        case .balance: L10n.projectIconBalance
        case .globalWorkspace, .global: L10n.projectIconGlobal
        case .travel: L10n.projectIconTravel
        case .tools: L10n.projectIconTools
        case .animals: L10n.projectIconAnimals
        case .science: L10n.projectIconScience
        case .ideas: L10n.projectIconIdeas
        case .favorite: L10n.projectIconFavorite
        }
    }
}
