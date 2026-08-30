import Foundation
import GRDB

/// サイドバーの段階表示に必要な情報だけを保持する軽量なミーティング行。
struct MeetingSidebarItem: Equatable, FetchableRecord, Identifiable, Sendable {
    var meetingId: UUID
    var vaultId: UUID
    var projectId: UUID?
    var projectName: String?
    var meetingName: String
    var status: MeetingStatus
    var duration: TimeInterval?
    var createdAt: Date
    var recordingStartedAt: Date?
    var calendarEventTitle: String?
    var searchMatchContext: MeetingSearchMatchContext?
    var isSemanticHit = false

    var id: UUID { meetingId }

    var displayTitle: String {
        meetingName.nilIfBlank ?? L10n.newMeeting
    }

    var effectiveRecordingStartedAt: Date {
        recordingStartedAt ?? createdAt
    }

    init(
        meetingId: UUID,
        vaultId: UUID,
        projectId: UUID?,
        projectName: String?,
        meetingName: String,
        status: MeetingStatus,
        duration: TimeInterval?,
        createdAt: Date,
        recordingStartedAt: Date? = nil,
        calendarEventTitle: String?,
        searchMatchContext: MeetingSearchMatchContext? = nil
    ) {
        self.meetingId = meetingId
        self.vaultId = vaultId
        self.projectId = projectId
        self.projectName = projectName
        self.meetingName = meetingName
        self.status = status
        self.duration = duration
        self.createdAt = createdAt
        self.recordingStartedAt = recordingStartedAt
        self.calendarEventTitle = calendarEventTitle
        self.searchMatchContext = searchMatchContext
    }

    init(detail: MeetingDetailItem) {
        self.init(
            meetingId: detail.meetingId,
            vaultId: detail.vaultId,
            projectId: detail.projectId,
            projectName: detail.projectName,
            meetingName: detail.meetingName,
            status: detail.status,
            duration: detail.duration,
            createdAt: detail.createdAt,
            recordingStartedAt: detail.recordingStartedAt,
            calendarEventTitle: detail.calendarEvent?.title
        )
    }

    init(row: Row) throws {
        meetingId = row["meetingId"]
        vaultId = row["vaultId"]
        projectId = row["projectId"]
        projectName = row["projectName"]
        meetingName = row["meetingName"]
        status = row["status"]
        duration = row["duration"]
        createdAt = row["createdAt"]
        recordingStartedAt = row["recordingStartedAt"]
        calendarEventTitle = row["calendarEventTitle"]
        searchMatchContext = nil
    }
}

struct MeetingSidebarCursor: Equatable, Sendable {
    let effectiveRecordingStartedAt: Date
    let meetingId: UUID

    init(effectiveRecordingStartedAt: Date, meetingId: UUID) {
        self.effectiveRecordingStartedAt = effectiveRecordingStartedAt
        self.meetingId = meetingId
    }

    init(item: MeetingSidebarItem) {
        effectiveRecordingStartedAt = item.effectiveRecordingStartedAt
        meetingId = item.meetingId
    }
}

struct MeetingSidebarPage: Equatable, Sendable {
    let items: [MeetingSidebarItem]
    let groups: [MeetingDateGroup]
    let hasMore: Bool
    let nextCursor: MeetingSidebarCursor?
}

enum MeetingSearchCursor: Equatable, Sendable {
    case chronological(MeetingSidebarCursor)
    case relevance(indexRevision: Int, offset: Int)
    case hybrid(ftsRevision: Int, vectorRevision: Int, offset: Int)
}

struct MeetingSearchPage: Equatable, Sendable {
    let items: [MeetingSidebarItem]
    let groups: [MeetingDateGroup]
    let hasMore: Bool
    let nextCursor: MeetingSearchCursor?
    let replacesResults: Bool
}
