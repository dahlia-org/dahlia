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
    public let referencesExpectation: String
}

public enum CustomerIntelligenceProposalAccessStatus: String, Codable, Sendable {
    case proposed
    case applied
    case rejected
    case stale
}

public struct CustomerIntelligenceProposalAccessQuery: Sendable, Equatable {
    public var status: CustomerIntelligenceProposalAccessStatus?
    public var limit: Int
    public var cursor: String?

    public init(
        status: CustomerIntelligenceProposalAccessStatus? = nil,
        limit: Int = 25,
        cursor: String? = nil
    ) {
        self.status = status
        self.limit = limit
        self.cursor = cursor
    }
}

public struct CustomerIntelligenceProposalEvidenceAccessMetadata: Codable, Sendable, Equatable {
    public let resourceType: CustomerIntelligenceResourceKind
    public let resourceID: UUID
    public let note: String?
}

public struct CustomerIntelligenceProposalAccessMetadata: Codable, Sendable, Equatable {
    public let id: UUID
    public let operationType: CustomerIntelligenceProposalOperationType
    public let payload: CustomerIntelligenceProposalPayload
    public let status: CustomerIntelligenceProposalAccessStatus
    public let staleReason: String?
    public let revision: Int
    public let evidence: [CustomerIntelligenceProposalEvidenceAccessMetadata]
    public let dependencies: [UUID]
    public let createdAt: Date
    public let updatedAt: Date
}

public struct CustomerIntelligenceProposalAccessPage: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let proposals: [CustomerIntelligenceProposalAccessMetadata]
    public let nextCursor: String?
}

public struct CustomerIntelligenceProposalCreationResult: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let proposalIDsByLocalKey: [String: UUID]
    public let entityIDsByLocalKey: [String: UUID]
}

public struct CustomerIntelligenceProposalMutationResult: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let proposalIDs: [UUID]
}
