import DahliaRuntimeSupport
import Foundation

public struct MeetingQuery: Sendable, Equatable {
    public var query: String?
    public var project: String?
    public var projectID: UUID?
    public var organizationID: UUID?
    public var includeOrganizationDescendants: Bool
    public var topicID: UUID?
    public var icalUID: String?
    public var createdFrom: Date?
    public var createdBefore: Date?
    public var limit: Int
    public var cursor: String?

    public init(
        query: String? = nil,
        project: String? = nil,
        projectID: UUID? = nil,
        organizationID: UUID? = nil,
        includeOrganizationDescendants: Bool = false,
        topicID: UUID? = nil,
        icalUID: String? = nil,
        createdFrom: Date? = nil,
        createdBefore: Date? = nil,
        limit: Int = 25,
        cursor: String? = nil
    ) {
        self.query = query
        self.project = project
        self.projectID = projectID
        self.organizationID = organizationID
        self.includeOrganizationDescendants = includeOrganizationDescendants
        self.topicID = topicID
        self.icalUID = icalUID
        self.createdFrom = createdFrom
        self.createdBefore = createdBefore
        self.limit = limit
        self.cursor = cursor
    }
}

public struct MeetingQueryPage: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let meetings: [MeetingMetadata]
    public let nextCursor: String?
}

public struct ScopedVault: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
}

public struct MeetingMetadata: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let description: String
    public let project: String?
    public let projectID: UUID?
    public let icalUID: String?
    public let recurrenceID: String?
    public let calendarTitle: String?
    public let status: String
    public let durationSeconds: Double?
    public let createdAt: Date
    public let hasSummary: Bool
    public let transcriptSegmentCount: Int
    public let tags: [String]
}

public struct MeetingDetail: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let meeting: MeetingMetadata
    public let summary: String?
    public let summaryDocument: JSONValue?
    /// `update_meeting_summary` に渡す compare-and-swap 用の版。
    public let summaryDocumentVersion: String?
}

public struct SummaryMutationResult: Codable, Sendable, Equatable {
    public enum VaultExportOutcome: String, Codable, Sendable {
        /// Vault の Markdown を新しい内容で書き直した。
        case updated
        /// 送られたドキュメントが保存済みと同一だったため、何も書かなかった。
        case unchanged
        /// この要約はまだ Vault へ書き出されていないため、ファイルは作らなかった。
        case notExported = "not_exported"
        /// 書き出し記録はあるが実ファイルへ到達できなかったため、データベースだけ更新した。
        case fileMissing = "file_missing"
    }

    public let meetingID: UUID
    public let documentVersion: String
    public let title: String
    public let description: String
    public let changed: Bool
    public let vaultExport: VaultExportOutcome
    /// 追従できず古いままになっている書き出し先。
    public let staleExports: [String]
}

public struct TranscriptPage: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let meetingID: UUID
    public let segments: [TranscriptEntry]
    public let nextCursor: String?
}

public struct TranscriptEntry: Codable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let speaker: String?
    public let startedAt: Date
    public let endedAt: Date?
    public let elapsedSeconds: Double
    public let endedElapsedSeconds: Double?
    public let timestamp: String
}

public struct ScreenshotQuery: Sendable, Equatable {
    public var fromElapsedSeconds: Double?
    public var toElapsedSeconds: Double?
    public var limit: Int
    public var cursor: String?

    public init(
        fromElapsedSeconds: Double? = nil,
        toElapsedSeconds: Double? = nil,
        limit: Int = 20,
        cursor: String? = nil
    ) {
        self.fromElapsedSeconds = fromElapsedSeconds
        self.toElapsedSeconds = toElapsedSeconds
        self.limit = limit
        self.cursor = cursor
    }
}

public struct MeetingScreenshotPage: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let meetingID: UUID
    public let screenshots: [MeetingScreenshotMetadata]
    public let nextCursor: String?
}

public struct MeetingScreenshotMetadata: Codable, Sendable, Equatable {
    public let id: UUID
    public let capturedAt: Date
    public let elapsedSeconds: Double
    public let timestamp: String
    public let mimeType: String
    public let isReferencedInSummary: Bool
}

public struct MeetingScreenshotImage: Sendable, Equatable {
    public let metadata: MeetingScreenshotMetadata
    public let imageData: Data
    public let mimeType: String
}

public enum ProjectWorkspaceType: String, Codable, CaseIterable, Sendable {
    case customer
    case `internal`
    case personal
    case undefined
}

public struct ProjectQuery: Sendable, Equatable {
    public var query: String?
    public var projectID: UUID?
    public var type: ProjectWorkspaceType?

    public init(query: String? = nil, projectID: UUID? = nil, type: ProjectWorkspaceType? = nil) {
        self.query = query
        self.projectID = projectID
        self.type = type
    }
}

public struct ProjectMetadata: Codable, Sendable, Equatable {
    public let projectID: UUID
    public let name: String
    public let path: String
    public let parentProjectID: UUID?
    public let rootProjectID: UUID
    public let explicitType: ProjectWorkspaceType?
    public let effectiveType: ProjectWorkspaceType
    public let typeOwnerProjectID: UUID
    public let isTypeInherited: Bool
    public let directMeetingCount: Int
    public let descendantMeetingCount: Int
    public let description: String
    public let revision: Int
}

public struct ProjectQueryResult: Codable, Sendable, Equatable {
    public let vault: ScopedVault
    public let projects: [ProjectMetadata]
}

public enum ProjectParentUpdate: Sendable, Equatable {
    case unchanged
    case vaultRoot
    case project(UUID)
}

public struct ProjectUpdate: Sendable, Equatable {
    public var name: String?
    public var parent: ProjectParentUpdate
    public var description: String?
    public var projectType: ProjectWorkspaceType?
    public var expectedRevision: Int

    public init(
        name: String? = nil,
        parent: ProjectParentUpdate = .unchanged,
        description: String? = nil,
        projectType: ProjectWorkspaceType? = nil,
        expectedRevision: Int
    ) {
        self.name = name
        self.parent = parent
        self.description = description
        self.projectType = projectType
        self.expectedRevision = expectedRevision
    }
}

public struct ProjectMutationResult: Codable, Sendable, Equatable {
    public let project: ProjectMetadata
    public let changed: Bool
    public let affectedProjectIDs: [UUID]
    public let effectiveTypeChangedProjectIDs: [UUID]
}

public struct MeetingProjectMembershipExpectation: Sendable, Equatable {
    public let meetingID: UUID
    public let expectedProjectID: UUID?

    public init(meetingID: UUID, expectedProjectID: UUID?) {
        self.meetingID = meetingID
        self.expectedProjectID = expectedProjectID
    }
}

public struct MeetingProjectMembershipResult: Codable, Sendable, Equatable {
    public let changed: Bool
    public let changedMeetingIDs: [UUID]
    public let projectID: UUID?
}

public typealias JSONValue = DahliaRuntimeSupport.JSONValue

public enum MeetingAccessError: Error, LocalizedError, Equatable {
    case vaultNotFound
    case meetingNotFound
    case databaseUpgradeRequired
    case invalidSummaryDocument
    case invalidCursor
    case invalidLimit(maximum: Int)
    case invalidTimeRange
    case screenshotNotFound
    case screenshotEncodingFailed
    case writeAccessRequired
    case projectNotFound
    case projectConflict(String)
    case invalidProjectName
    case projectHierarchyTooDeep
    case projectAlreadyExists(String)
    case projectFileConflict(String)
    case projectTypeOwnedByRoot
    case meetingMembershipConflict
    case organizationNotFound
    case contactNotFound
    case conversationTopicNotFound
    case insightNotFound
    case invalidResourceFilter
    case invalidCustomerIntelligenceData
    case workspaceBusy
    case workspaceRollbackFailed
    case invalidCustomerIntelligenceMutation
    case invalidCustomerIntelligenceReference
    case customerIntelligenceRevisionConflict
    case customerIntelligenceResourceInUse(String)
    case duplicateContactEmail
    case summaryNotFound
    case summaryVersionConflict
    case summaryScreenshotNotFound
    case invalidSummaryUpdate(String)

    public var errorDescription: String? {
        switch self {
        case .vaultNotFound:
            "The configured vault was not found."
        case .meetingNotFound:
            "The meeting was not found in the configured vault."
        case .databaseUpgradeRequired:
            "The Dahlia database must be upgraded before meeting access can start. Open Dahlia once, then try again."
        case .invalidSummaryDocument:
            "The stored summary document is invalid. Open Dahlia and regenerate the summary."
        case .invalidCursor:
            "The cursor is invalid for the configured vault or meeting."
        case let .invalidLimit(maximum):
            "The limit must be between 1 and \(maximum)."
        case .invalidTimeRange:
            "Elapsed time values must be finite and nonnegative, and the start must be before the end."
        case .screenshotNotFound:
            "The screenshot was not found in the configured meeting and vault."
        case .screenshotEncodingFailed:
            "The screenshot could not be prepared for MCP access."
        case .writeAccessRequired:
            "This dahlia-mcp process is read-only. Restart it with --write to use update tools."
        case .projectNotFound:
            "The project was not found in the configured vault."
        case let .projectConflict(message):
            "Project update conflict: \(message)"
        case .invalidProjectName:
            "Project name must be a non-hidden single path component."
        case .projectHierarchyTooDeep:
            "Projects support one level of subprojects. The parent must be a root project."
        case let .projectAlreadyExists(name):
            "A Project named \(name) already exists under that parent."
        case let .projectFileConflict(path):
            "A directory or file already exists at \(path)."
        case .projectTypeOwnedByRoot:
            "Only a root project can have an explicit project type."
        case .meetingMembershipConflict:
            "At least one meeting no longer has the expected project membership; no meetings were changed."
        case .organizationNotFound:
            "The organization was not found in the configured vault."
        case .contactNotFound:
            "The contact was not found in the configured vault."
        case .conversationTopicNotFound:
            "The conversation topic was not found in the configured vault."
        case .insightNotFound:
            "The insight was not found in the configured vault."
        case .invalidResourceFilter:
            "resource_type and resource_id must be supplied together, using a supported resource type."
        case .invalidCustomerIntelligenceData:
            "Stored customer intelligence data is invalid. Open Dahlia and repair or remove the affected record."
        case .workspaceBusy:
            "Another Dahlia process is updating this vault. Refresh the project state and try again."
        case .workspaceRollbackFailed:
            "The workspace update failed and its filesystem rollback also failed."
        case .invalidCustomerIntelligenceMutation:
            "The customer intelligence change is invalid."
        case .invalidCustomerIntelligenceReference:
            "The related resource does not exist in the configured vault or is not supported."
        case .customerIntelligenceRevisionConflict:
            "The record changed after it was read. Query it again before retrying."
        case let .customerIntelligenceResourceInUse(message):
            message
        case .duplicateContactEmail:
            "Another Contact already uses this email. Use resolve_contact when merging a provisional Contact."
        case .summaryNotFound:
            "The meeting has no summary yet. Generate the summary in Dahlia before updating it."
        case .summaryVersionConflict:
            "The summary changed after it was read. Call get_meeting again before retrying."
        case .summaryScreenshotNotFound:
            "An image block references a screenshot that does not belong to this meeting."
        case let .invalidSummaryUpdate(message):
            message
        }
    }

    public var reasonCode: String {
        switch self {
        case .vaultNotFound, .meetingNotFound, .projectNotFound, .organizationNotFound,
             .contactNotFound, .conversationTopicNotFound, .insightNotFound,
             .screenshotNotFound, .summaryNotFound:
            "not_found"
        case .projectConflict, .meetingMembershipConflict, .customerIntelligenceRevisionConflict,
             .summaryVersionConflict:
            "revision_conflict"
        case .customerIntelligenceResourceInUse:
            "resource_in_use"
        case .duplicateContactEmail:
            "duplicate_email"
        case .invalidResourceFilter, .invalidCustomerIntelligenceReference, .summaryScreenshotNotFound:
            "invalid_reference"
        case .workspaceBusy:
            "database_busy"
        default:
            "invalid_input"
        }
    }
}
