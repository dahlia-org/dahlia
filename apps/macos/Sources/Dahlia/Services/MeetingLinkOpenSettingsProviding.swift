@MainActor
protocol MeetingLinkOpenSettingsProviding: AnyObject {
    var defaultMeetingLinkOpenTarget: MeetingLinkOpenTarget { get }
    func meetingLinkOpenTarget(for service: MeetingLinkService) -> MeetingLinkOpenTarget
}

extension AppSettings: MeetingLinkOpenSettingsProviding {}
