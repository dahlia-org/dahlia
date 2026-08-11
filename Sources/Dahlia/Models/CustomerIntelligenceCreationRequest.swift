import Foundation

enum CustomerIntelligenceCreationRequest: Identifiable {
    case organization(parentID: UUID?)
    case contact(organizationID: UUID?)
    case project(organizationID: UUID?)
    case topic(organizationID: UUID?)

    var id: String {
        switch self {
        case let .organization(parentID):
            "organization:\(parentID?.uuidString ?? "root")"
        case let .contact(organizationID):
            "contact:\(organizationID?.uuidString ?? "none")"
        case let .project(organizationID):
            "project:\(organizationID?.uuidString ?? "none")"
        case let .topic(organizationID):
            "topic:\(organizationID?.uuidString ?? "none")"
        }
    }

    var initialOrganizationID: UUID? {
        switch self {
        case let .organization(parentID):
            parentID
        case let .contact(organizationID), let .project(organizationID), let .topic(organizationID):
            organizationID
        }
    }
}
