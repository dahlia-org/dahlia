import Foundation

enum AppAccountScope: Hashable, Sendable {
    case local
    case dahlia(UUID)

    init(connectionID: UUID?) {
        self = connectionID.map(Self.dahlia) ?? .local
    }

    var storageKey: String {
        switch self {
        case .local: "local"
        case let .dahlia(id): "dahlia.\(id.uuidString.lowercased())"
        }
    }
}
