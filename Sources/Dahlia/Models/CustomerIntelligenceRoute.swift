import Foundation

enum CustomerIntelligenceSection: String, CaseIterable, Identifiable, Sendable {
    case overview
    case organizations
    case contacts
    case projects
    case topics
    case insights

    var id: String { rawValue }
}

enum CustomerIntelligenceScope: Hashable, Sendable {
    case all
    case organization(UUID)

    var organizationID: UUID? {
        if case let .organization(id) = self {
            id
        } else {
            nil
        }
    }
}

struct CustomerIntelligenceSelection: Equatable, Sendable {
    var organizationID: UUID?
    var contactID: UUID?
    var projectID: UUID?
    var topicID: UUID?
    var insightID: UUID?
}

enum CustomerIntelligenceTableDensity: String, CaseIterable, Identifiable, Sendable {
    case standard
    case compact

    var id: String { rawValue }
}
