import Foundation

enum CodexChatContext: Equatable {
    case meeting(
        id: UUID,
        name: String,
        calendarEvent: CodexChatCalendarEventContext?
    )
    case meetingDraft(
        id: UUID?,
        name: String,
        calendarEvent: CodexChatCalendarEventContext?
    )

    var meetingName: String {
        switch self {
        case let .meeting(_, name, _), let .meetingDraft(_, name, _):
            name
        }
    }

    var calendarEvent: CodexChatCalendarEventContext? {
        switch self {
        case let .meeting(_, _, calendarEvent), let .meetingDraft(_, _, calendarEvent):
            calendarEvent
        }
    }

    var isDraft: Bool {
        if case .meetingDraft = self {
            true
        } else {
            false
        }
    }

    func sharesConversationSection(with other: Self) -> Bool {
        switch (self, other) {
        case let (.meeting(id, _, _), .meeting(otherID, _, _)):
            return id == otherID
        case let (.meetingDraft(id?, _, _), .meetingDraft(otherID?, _, _)):
            return id == otherID
        case (.meetingDraft(nil, _, _), .meetingDraft(nil, _, _)):
            if let calendarIdentity,
               let otherIdentity = other.calendarIdentity {
                return calendarIdentity == otherIdentity
            }
            return self == other
        case (.meetingDraft, .meeting), (.meeting, .meetingDraft):
            guard let calendarIdentity,
                  let otherIdentity = other.calendarIdentity else { return false }
            return calendarIdentity == otherIdentity
        default:
            return false
        }
    }

    private var calendarIdentity: String? {
        guard let calendarEvent,
              let icalUID = calendarEvent.icalUID?.nilIfBlank else { return nil }
        return "\(icalUID)\u{1F}\(calendarEvent.start.timeIntervalSinceReferenceDate)"
    }
}
