@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingNotificationPresentationTests {
        @Test
        func defaultsToSystemNotification() {
            #expect(MeetingNotificationPresentation.defaultValue == .systemNotification)
            #expect(MeetingNotificationPresentation(storedRawValue: "unsupported") == .systemNotification)
        }

        @Test
        func restoresSystemNotification() {
            #expect(MeetingNotificationPresentation(
                storedRawValue: MeetingNotificationPresentation.systemNotification.rawValue
            ) == .systemNotification)
        }
    }
#endif
