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
    var calendarEventTitle: String?

    var id: UUID { meetingId }

    init(
        meetingId: UUID,
        vaultId: UUID,
        projectId: UUID?,
        projectName: String?,
        meetingName: String,
        status: MeetingStatus,
        duration: TimeInterval?,
        createdAt: Date,
        calendarEventTitle: String?
    ) {
        self.meetingId = meetingId
        self.vaultId = vaultId
        self.projectId = projectId
        self.projectName = projectName
        self.meetingName = meetingName
        self.status = status
        self.duration = duration
        self.createdAt = createdAt
        self.calendarEventTitle = calendarEventTitle
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
        calendarEventTitle = row["calendarEventTitle"]
    }
}

struct MeetingSidebarCursor: Equatable, Sendable {
    let createdAt: Date
    let meetingId: UUID

    init(createdAt: Date, meetingId: UUID) {
        self.createdAt = createdAt
        self.meetingId = meetingId
    }

    init(item: MeetingSidebarItem) {
        createdAt = item.createdAt
        meetingId = item.meetingId
    }
}

struct MeetingSidebarPage: Equatable, Sendable {
    let items: [MeetingSidebarItem]
    let groups: [MeetingDateGroup]
    let hasMore: Bool
    let nextCursor: MeetingSidebarCursor?
}
