import Foundation

public enum OrganizationAccessNodeKind: String, Codable, Sendable {
    case organization
    case unit
}

public enum CustomerResourceAccessType: String, Codable, Sendable {
    case organization
    case contact
    case project
    case meeting
}

public enum InsightAccessReferenceRole: String, Codable, Sendable {
    case context
    case evidence
    case mentioned
}

public struct OrganizationAccessQuery: Sendable, Equatable {
    public var query: String?
    public var nodeKind: OrganizationAccessNodeKind?
    public var parentOrganizationID: UUID?
    public var rootsOnly: Bool
    public var limit: Int
    public var cursor: String?

    public init(
        query: String? = nil,
        nodeKind: OrganizationAccessNodeKind? = nil,
        parentOrganizationID: UUID? = nil,
        rootsOnly: Bool = false,
        limit: Int = 25,
        cursor: String? = nil
    ) {
        self.query = query
        self.nodeKind = nodeKind
        self.parentOrganizationID = parentOrganizationID
        self.rootsOnly = rootsOnly
        self.limit = limit
        self.cursor = cursor
    }
}

public struct OrganizationAccessMetadata: Codable, Sendable, Equatable {
    public let id: UUID
    public let parentOrganizationID: UUID?
    public let nodeKind: OrganizationAccessNodeKind
    public let name: String
    public let primaryDomain: String?
    public let domainCount: Int
    public let memberCount: Int
    public let childCount: Int
    public let revision: Int
    public let createdAt: Date
    public let updatedAt: Date
}

public struct OrganizationAccessPage: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let organizations: [OrganizationAccessMetadata]
    public let nextCursor: String?
}

public struct OrganizationDomainAccessMetadata: Codable, Sendable, Equatable {
    public let domainName: String
    public let isPrimary: Bool
    public let firstObservedAt: Date
    public let lastObservedAt: Date
}

public struct OrganizationMemberAccessMetadata: Codable, Sendable, Equatable {
    public let contactID: UUID
    public let email: String?
    public let displayName: String?
    public let isProvisional: Bool
    public let revision: Int
    public let roleLabel: String?

    private enum CodingKeys: String, CodingKey {
        case contactID
        case email
        case displayName
        case isProvisional
        case revision
        case roleLabel
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contactID, forKey: .contactID)
        try container.encode(email, forKey: .email)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encode(isProvisional, forKey: .isProvisional)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(roleLabel, forKey: .roleLabel)
    }
}

public struct OrganizationAccessDetail: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let organization: OrganizationAccessMetadata
    public let domains: [OrganizationDomainAccessMetadata]
    public let domainsTruncated: Bool
    public let members: [OrganizationMemberAccessMetadata]
    public let membersTruncated: Bool
    public let projectResources: [ProjectResourceAccessMetadata]
    public let projectResourcesTruncated: Bool
}

public struct ContactAccessQuery: Sendable, Equatable {
    public var query: String?
    public var organizationID: UUID?
    public var limit: Int
    public var cursor: String?

    public init(
        query: String? = nil,
        organizationID: UUID? = nil,
        limit: Int = 25,
        cursor: String? = nil
    ) {
        self.query = query
        self.organizationID = organizationID
        self.limit = limit
        self.cursor = cursor
    }
}

public struct ContactAccessMetadata: Codable, Sendable, Equatable {
    public let id: UUID
    public let email: String?
    public let displayName: String?
    public let isProvisional: Bool
    public let revision: Int
    public let organizationCount: Int
    public let meetingCount: Int
    public let lastInteractionAt: Date?
    public let createdAt: Date
    public let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName
        case isProvisional
        case revision
        case organizationCount
        case meetingCount
        case lastInteractionAt
        case createdAt
        case updatedAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(email, forKey: .email)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encode(isProvisional, forKey: .isProvisional)
        try container.encode(revision, forKey: .revision)
        try container.encode(organizationCount, forKey: .organizationCount)
        try container.encode(meetingCount, forKey: .meetingCount)
        try container.encodeIfPresent(lastInteractionAt, forKey: .lastInteractionAt)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

public struct ContactAccessPage: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let contacts: [ContactAccessMetadata]
    public let nextCursor: String?
}

public struct ContactMembershipAccessMetadata: Codable, Sendable, Equatable {
    public let organizationID: UUID
    public let organizationName: String
    public let nodeKind: OrganizationAccessNodeKind
    public let roleLabel: String?
}

public struct ContactMeetingAccessMetadata: Codable, Sendable, Equatable {
    public let meetingID: UUID
    public let meetingName: String
    public let createdAt: Date
    public let role: String
    public let responseStatus: String
    public let source: String
}

public struct ContactAccessDetail: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let contact: ContactAccessMetadata
    public let memberships: [ContactMembershipAccessMetadata]
    public let membershipsTruncated: Bool
    public let recentMeetings: [ContactMeetingAccessMetadata]
    public let projectResources: [ProjectResourceAccessMetadata]
    public let projectResourcesTruncated: Bool
}

public struct ProjectResourceAccessQuery: Sendable, Equatable {
    public var projectID: UUID
    public var resourceType: CustomerResourceAccessType?
    public var limit: Int
    public var cursor: String?

    public init(
        projectID: UUID,
        resourceType: CustomerResourceAccessType? = nil,
        limit: Int = 25,
        cursor: String? = nil
    ) {
        self.projectID = projectID
        self.resourceType = resourceType
        self.limit = limit
        self.cursor = cursor
    }
}

public struct ProjectResourceAccessMetadata: Codable, Sendable, Equatable {
    public let id: UUID
    public let projectID: UUID
    public let projectName: String
    public let resourceType: CustomerResourceAccessType
    public let resourceID: UUID
    public let resourceName: String?
    public let relationLabel: String
    public let createdAt: Date
    public let updatedAt: Date
}

public struct ProjectResourceAccessPage: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let resources: [ProjectResourceAccessMetadata]
    public let nextCursor: String?
}

public struct InsightAccessQuery: Sendable, Equatable {
    public var isAccepted: Bool?
    public var resourceType: CustomerResourceAccessType?
    public var resourceID: UUID?
    public var limit: Int
    public var cursor: String?

    public init(
        isAccepted: Bool? = nil,
        resourceType: CustomerResourceAccessType? = nil,
        resourceID: UUID? = nil,
        limit: Int = 25,
        cursor: String? = nil
    ) {
        self.isAccepted = isAccepted
        self.resourceType = resourceType
        self.resourceID = resourceID
        self.limit = limit
        self.cursor = cursor
    }
}

public struct InsightReferenceAccessMetadata: Codable, Sendable, Equatable {
    public let resourceType: CustomerResourceAccessType
    public let resourceID: UUID
    public let resourceName: String?
    public let referenceRole: InsightAccessReferenceRole
    public let createdAt: Date
}

public struct InsightAccessMetadata: Codable, Sendable, Equatable {
    public let id: UUID
    public let content: String
    public let isAccepted: Bool
    public let metadata: JSONValue
    public let revision: Int
    public let references: [InsightReferenceAccessMetadata]
    public let referencesTruncated: Bool
    public let referencesExpectation: String
    public let createdAt: Date
    public let updatedAt: Date
}

public struct InsightAccessPage: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let insights: [InsightAccessMetadata]
    public let nextCursor: String?
}

public struct InsightAccessDetail: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let insight: InsightAccessMetadata
}
