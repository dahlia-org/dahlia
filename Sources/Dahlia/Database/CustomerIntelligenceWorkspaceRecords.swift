import Foundation
import GRDB

struct ConversationTopicRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "conversation_topics"

    var id: UUID
    var vaultId: UUID
    var title: String
    var currentState: String
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
}

struct ConversationTopicReferenceRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "conversation_topic_references"

    var topicId: UUID
    var resourceType: ConversationTopicResourceType
    var resourceId: UUID
    var note: String?
    var createdAt: Date
    var updatedAt: Date
}

struct ConversationTopicOverview: Equatable, Identifiable, Sendable {
    let topic: ConversationTopicRecord
    let lastDiscussedAt: Date?
    let meetingCount: Int
    let organizationCount: Int

    var id: UUID { topic.id }
}

struct ProvisionalContactDeletionImpact: Equatable, Sendable {
    let memberships: Int
    let projects: Int
    let insights: Int
    let topics: Int
    let meetingParticipants: Int
}

struct OrganizationDeletionImpact: Equatable, Sendable {
    let organizationCount: Int
    let memberships: Int
    let projects: Int
    let topics: Int
}

struct TopicDeletionImpact: Equatable, Sendable {
    let meetings: Int
    let relatedResources: Int
}

struct ConversationTopicMeetingEvidence: Equatable, Identifiable, Sendable {
    let meeting: MeetingRecord
    let note: String

    var id: UUID { meeting.id }
}

struct OrganizationWorkspaceNode: Equatable, Identifiable, Sendable {
    let organization: OrganizationRecord
    let childCount: Int

    var id: UUID { organization.id }
}

struct OrganizationWorkspaceMember: Equatable, Identifiable, Sendable {
    let contact: ContactRecord
    let roleLabel: String?

    var id: UUID { contact.id }
}

struct OrganizationWorkspaceDetail: Equatable, Sendable {
    let members: [OrganizationWorkspaceMember]
    let projects: [ProjectRecord]
    let topics: [ConversationTopicOverview]
    let recentMeetings: [MeetingRecord]
}
