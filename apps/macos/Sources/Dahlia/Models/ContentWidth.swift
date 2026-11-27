import CoreGraphics

/// How wide the main content can grow on large windows. Chats and the other screens each store their own choice on this Mac.
enum ContentWidth: String, CaseIterable, Identifiable {
    case comfortable
    case wide
    case full

    static let chatUserDefaultsKey = "chatContentWidth"
    static let mainUserDefaultsKey = "mainContentWidth"
    static let chatDefault = Self.comfortable
    static let mainDefault = Self.wide

    var id: Self { self }

    var maxWidth: CGFloat {
        switch self {
        case .comfortable: 736 // T3 Code's comfortable chat width, 46rem.
        case .wide: 1000
        case .full: .infinity
        }
    }

    func label(default defaultWidth: Self) -> String {
        let name = switch self {
        case .comfortable: L10n.contentWidthComfortable
        case .wide: L10n.contentWidthWide
        case .full: L10n.contentWidthFull
        }
        return self == defaultWidth ? L10n.contentWidthDefault(name) : name
    }
}
