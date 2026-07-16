import Foundation
import GRDB

@MainActor
final class CodexChatContextProvider: CodexChatContextProviding {
    private var vaultID: UUID?
    private var meetingID: UUID?
    private var draftMeeting: DraftMeeting?
    private var dbQueue: DatabaseQueue?

    func update(
        vaultID: UUID?,
        meetingID: UUID?,
        draftMeeting: DraftMeeting?,
        dbQueue: DatabaseQueue?
    ) {
        self.vaultID = vaultID
        self.meetingID = meetingID
        self.draftMeeting = draftMeeting
        self.dbQueue = dbQueue
    }

    func currentContext(vaultID: UUID) async throws -> CodexChatContext? {
        guard self.vaultID == vaultID else { return nil }
        if let draftMeeting {
            return .meetingDraft(
                id: draftMeeting.id,
                name: draftMeeting.title,
                calendarEvent: draftMeeting.linkedCalendarEvent.map(Self.calendarContext)
            )
        }

        guard let meetingID else { return nil }
        guard let dbQueue else { throw CodexChatContextError.selectedMeetingUnavailable }
        let repository = MeetingRepository(dbQueue: dbQueue)
        let detail = try await repository.fetchCodexChatContext(id: meetingID)
        guard let meeting = detail.meeting,
              meeting.vaultId == vaultID else {
            throw CodexChatContextError.selectedMeetingUnavailable
        }
        return .meeting(
            id: meeting.id,
            name: meeting.name,
            calendarEvent: detail.calendarEvent.map(Self.calendarContext)
        )
    }

    private static func calendarContext(_ event: CalendarEvent) -> CodexChatCalendarEventContext {
        CodexChatCalendarEventContext(
            icalUID: event.icalUid,
            title: event.title,
            description: event.description,
            start: event.startDate,
            end: event.endDate
        )
    }

    private static func calendarContext(_ event: CalendarEventRecord) -> CodexChatCalendarEventContext {
        CodexChatCalendarEventContext(
            icalUID: event.icalUid,
            title: event.title,
            description: event.description,
            start: event.start,
            end: event.end
        )
    }
}

enum CodexChatContextError: LocalizedError, Equatable {
    case selectedMeetingUnavailable

    var errorDescription: String? {
        switch self {
        case .selectedMeetingUnavailable:
            L10n.chatSelectedMeetingUnavailable
        }
    }
}
