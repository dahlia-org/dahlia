import DahliaRuntimeSupport
import Foundation

public struct OrganizationChartAccessQuery: Sendable, Equatable {
    public var rootOrganizationID: UUID
    public var maximumDepth: Int
    public var childrenPerNode: Int

    public init(rootOrganizationID: UUID, maximumDepth: Int = 8, childrenPerNode: Int = 50) {
        self.rootOrganizationID = rootOrganizationID
        self.maximumDepth = maximumDepth
        self.childrenPerNode = childrenPerNode
    }
}

public struct OrganizationChartAccessNode: Codable, Sendable, Equatable {
    public let id: UUID
    public let parentOrganizationID: UUID?
    public let nodeKind: OrganizationAccessNodeKind
    public let name: String
    public let depth: Int
    public let revision: Int
    public let memberCount: Int
    public let projectCount: Int
    public let topicCount: Int
    public let meetingCount: Int
    public let lastInteractionAt: Date?
    public let childCount: Int
    public let childrenTruncated: Bool
}

public struct OrganizationChartAccessResult: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let rootOrganizationID: UUID
    public let nodes: [OrganizationChartAccessNode]
    public let nodesTruncated: Bool
}

public struct ConversationTopicAccessQuery: Sendable, Equatable {
    public var organizationID: UUID?
    public var includeDescendants: Bool
    public var projectID: UUID?
    public var limit: Int
    public var cursor: String?

    public init(
        organizationID: UUID? = nil,
        includeDescendants: Bool = false,
        projectID: UUID? = nil,
        limit: Int = 25,
        cursor: String? = nil
    ) {
        self.organizationID = organizationID
        self.includeDescendants = includeDescendants
        self.projectID = projectID
        self.limit = limit
        self.cursor = cursor
    }
}

public struct ConversationTopicReferenceAccessMetadata: Codable, Sendable, Equatable {
    public let resourceType: CustomerIntelligenceResourceKind
    public let resourceID: UUID
    public let resourceName: String?
    public let note: String?
    public let createdAt: Date
}

public struct ConversationTopicAccessMetadata: Codable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let currentState: String
    public let revision: Int
    public let lastDiscussedAt: Date?
    public let meetingCount: Int
    public let organizationCount: Int
    public let createdAt: Date
    public let updatedAt: Date
}

public struct ConversationTopicAccessPage: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let topics: [ConversationTopicAccessMetadata]
    public let nextCursor: String?
}

public struct ConversationTopicAccessDetail: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let topic: ConversationTopicAccessMetadata
    public let references: [ConversationTopicReferenceAccessMetadata]
    public let referencesTruncated: Bool
    public let referencesExpectation: String
}

public enum OrganizationParentMutation: Sendable, Equatable {
    case unchanged
    case root
    case organization(UUID)
}

public enum CustomerIntelligenceRecordKind: String, Codable, Sendable, Equatable {
    case organization
    case contact
    case conversationTopic = "conversation_topic"
    case insight
}

public struct CustomerIntelligenceRecordMutationResult: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let resourceType: CustomerIntelligenceRecordKind
    public let resourceID: UUID
    public let revision: Int
    public let changed: Bool
}

public enum CustomerIntelligenceDeletionResourceKind: String, Codable, Sendable, Equatable {
    case organization
    case contact
    case conversationTopic = "conversation_topic"
    case insight
}

public struct CustomerIntelligenceRecordDeletionResult: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let resourceType: CustomerIntelligenceDeletionResourceKind
    public let resourceID: UUID
    public let changed: Bool
}

public enum CustomerIntelligenceRelationshipKind: String, Codable, Sendable, Equatable {
    case contactOrganizationMembership = "contact_organization_membership"
    case projectResourceReference = "project_resource_reference"
    case conversationTopicResourceReference = "conversation_topic_resource_reference"
    case insightResourceReference = "insight_resource_reference"
    case meetingProjectAssignment = "meeting_project_assignment"
}

public struct CustomerIntelligenceRelationshipMutationResult: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let relationship: CustomerIntelligenceRelationshipKind
    public let sourceID: UUID
    public let targetID: UUID?
    public let revision: Int?
    public let changed: Bool
}
