import Foundation

struct DraftMeeting: Equatable {
    var id: UUID
    var title: String
    var linkedCalendarEvent: CalendarEvent?
    var projectURL: URL?
    var projectId: UUID?
    var projectName: String?
    var allowsCalendarSeriesProjectInheritance = true
}

struct DraftMeetingMaterialization: Equatable {
    let draftID: UUID
    let meetingID: UUID
}
