import Foundation

struct CalendarEventDisplayInfo: Equatable {
    let title: String
    let description: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool

    var resolvedTitle: String {
        title.nilIfBlank ?? L10n.newMeeting
    }
}

extension CalendarEventDisplayInfo {
    init(event: CalendarEvent) {
        self.init(
            title: event.title,
            description: event.description,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay
        )
    }
}
