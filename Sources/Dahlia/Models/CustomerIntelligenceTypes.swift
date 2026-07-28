import Foundation
import GRDB

enum OrganizationNodeKind: String, Codable, CaseIterable, DatabaseValueConvertible, Sendable {
    case organization
    case unit
}

enum CustomerResourceType: String, Codable, CaseIterable, DatabaseValueConvertible, Sendable {
    case organization
    case contact
    case project
    case meeting
    case topic
}

enum ConversationTopicResourceType: String, Codable, CaseIterable, DatabaseValueConvertible, Sendable {
    case organization
    case contact
    case project
    case meeting
}

enum InsightReferenceRole: String, Codable, CaseIterable, DatabaseValueConvertible, Sendable {
    case context
    case evidence
    case mentioned
}

enum MeetingParticipantRole: String, Codable, CaseIterable, DatabaseValueConvertible, Sendable {
    case organizer
    case required
    case optional
    case attendee
    case unknown
}

enum MeetingParticipantResponseStatus: String, Codable, CaseIterable, DatabaseValueConvertible, Sendable {
    case accepted
    case declined
    case tentative
    case needsAction = "needs_action"
    case unknown
}

enum CustomerIntelligenceIngestionPolicy: Equatable, Sendable {
    case afterMeetingPersistence
    case afterCaptureStarts
}

enum CalendarParticipantKind: String, Codable, CaseIterable, Sendable {
    case person
    case room
    case resource
    case group
    case unknown
}
