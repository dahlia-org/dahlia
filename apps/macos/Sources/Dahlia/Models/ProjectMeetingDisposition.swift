import Foundation

enum ProjectMeetingDisposition: Equatable {
    case move(to: UUID)
    case deleteMeetings
}
