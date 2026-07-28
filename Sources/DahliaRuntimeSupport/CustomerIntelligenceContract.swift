import Foundation

public enum CustomerIntelligenceResourceKind: String, Codable, CaseIterable, Sendable {
    case organization
    case contact
    case project
    case meeting
    case topic
}

public struct CustomerIntelligenceTopicReferenceInput: Codable, Equatable, Sendable {
    public let resourceType: CustomerIntelligenceResourceKind
    public let resourceID: UUID
    public let note: String?

    public init(
        resourceType: CustomerIntelligenceResourceKind,
        resourceID: UUID,
        note: String? = nil
    ) {
        self.resourceType = resourceType
        self.resourceID = resourceID
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case resourceType = "resource_type"
        case resourceID = "resource_id"
        case note
    }
}
