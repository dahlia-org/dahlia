#if canImport(Testing)
    import Combine
    import Foundation
    import Testing
    @testable import Dahlia

    struct AccountMeetingSettingsTests {
        @Test
        func clearingTheLocaleKeyNotifiesObserversWithTheDefault() throws {
            let suiteName = "AccountMeetingSettingsTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set("xx_XX", forKey: AppSettings.liveSubtitleLocaleUserDefaultsKey)
            var observed: [String] = []
            // The publisher `CaptionViewModel` follows.
            let subscription = defaults.publisher(for: \.liveSubtitleLocale).sink { observed.append($0) }
            defer { subscription.cancel() }

            defaults.removeObject(forKey: AppSettings.liveSubtitleLocaleUserDefaultsKey)

            #expect(observed == ["xx_XX", Locale.current.identifier])
        }
    }
#endif
