@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingNotificationPresentationTests {
        @Test
        func defaultsToProminentPopup() {
            #expect(MeetingNotificationPresentation.defaultValue == .prominentPopup)
            #expect(MeetingNotificationPresentation(storedRawValue: "unsupported") == .prominentPopup)
        }

        @Test
        func restoresSystemNotification() {
            #expect(MeetingNotificationPresentation(
                storedRawValue: MeetingNotificationPresentation.systemNotification.rawValue
            ) == .systemNotification)
        }
    }
#endif
