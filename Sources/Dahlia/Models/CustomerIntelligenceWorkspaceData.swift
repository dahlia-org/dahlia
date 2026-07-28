import DahliaRuntimeSupport
import Foundation

enum CustomerIntelligenceWorkspaceData {
    struct Counts: Equatable, Sendable {
        let contacts: Int
        let projects: Int
        let topics: Int
        let meetings: Int
        let unacceptedInsights: Int

        static let empty = Self(
            contacts: 0,
            projects: 0,
            topics: 0,
            meetings: 0,
            unacceptedInsights: 0
        )
    }

    struct ResourceLink: Identifiable, Equatable, Sendable {
        let kind: CustomerIntelligenceResourceKind
        let resourceID: UUID
        let title: String
        let role: String?
        let note: String?

        var id: String {
            "\(kind.rawValue):\(resourceID.uuidString):\(role ?? "")"
        }
    }

    struct CustomerCard: Identifiable, Equatable, Sendable {
        let root: OrganizationWorkspaceNode
        let organizationCount: Int
        let contactCount: Int
        let projectCount: Int
        let topicCount: Int
        let lastInteractionAt: Date?

        var id: UUID { root.id }
    }

    struct Overview: Equatable, Sendable {
        let counts: Counts
        let customers: [CustomerCard]
        let keyContacts: [ContactSummary]
        let recentProjects: [ProjectSummary]
        let recentTopics: [ConversationTopicOverview]
        let recentMeetings: [MeetingRecord]
        let pendingInsights: [InsightSummary]

        static let empty = Self(
            counts: .empty,
            customers: [],
            keyContacts: [],
            recentProjects: [],
            recentTopics: [],
            recentMeetings: [],
            pendingInsights: []
        )
    }

    struct ContactSummary: Identifiable, Equatable, Sendable {
        let contact: ContactRecord
        let meetingCount: Int
        let lastInteractionAt: Date?
        let membershipCount: Int
        let organizationNames: [String]
        let roleLabels: [String]
        let topicCount: Int

        var id: UUID { contact.id }
        var sortName: String { contact.displayName ?? contact.email ?? "" }
        var sortProvisional: Int { contact.isProvisional ? 1 : 0 }
        var sortOrganizations: String { organizationNames.joined(separator: ", ") }
        var sortRoles: String { roleLabels.joined(separator: ", ") }
        var sortLastInteraction: Date { lastInteractionAt ?? .distantPast }
    }

    struct ContactMembership: Identifiable, Equatable, Sendable {
        let organization: OrganizationRecord
        let roleLabel: String?

        var id: UUID { organization.id }
    }

    struct ContactDetail: Equatable, Sendable {
        let summary: ContactSummary
        let memberships: [ContactMembership]
        let projects: [ResourceLink]
        let recentMeetings: [MeetingRecord]
        let topics: [ConversationTopicOverview]
    }

    struct TopicDetail: Equatable, Sendable {
        let overview: ConversationTopicOverview
        let references: [ResourceLink]
        let meetings: [ConversationTopicMeetingEvidence]
    }

    struct InsightSummary: Identifiable, Equatable, Sendable {
        let insight: InsightRecord
        let referenceCount: Int
        let relatedTitles: [String]

        var id: UUID { insight.id }
        var sortRelatedTitles: String { relatedTitles.joined(separator: ", ") }
        var sortAcceptance: Int { insight.isAccepted ? 1 : 0 }
    }

    struct InsightDetail: Equatable, Sendable {
        let summary: InsightSummary
        let references: [ResourceLink]
    }

    struct ProjectSummary: Identifiable, Equatable, Sendable {
        let project: ProjectRecord
        let effectiveType: ProjectType
        let organizationNames: [String]
        let contactNames: [String]
        let meetingCount: Int
        let latestMeetingDate: Date?

        var id: UUID { project.id }
        var sortPath: String { project.path }
        var sortType: String { effectiveType.rawValue }
        var sortOrganizations: String { organizationNames.joined(separator: ", ") }
        var sortContacts: String { contactNames.joined(separator: ", ") }
        var sortLatestMeetingDate: Date { latestMeetingDate ?? .distantPast }
    }

    struct ProjectDetail: Equatable, Sendable {
        let summary: ProjectSummary
        let references: [ResourceLink]
        let meetings: [MeetingRecord]
    }
}
