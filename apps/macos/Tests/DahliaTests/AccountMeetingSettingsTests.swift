#if canImport(Testing)
    import Combine
    import Foundation
    import Testing
    @testable import Dahlia

    struct AccountMeetingSettingsTests {
        @Test
        func meetingSettingsFromBeforePerAccountSettingsStayWithTheAccount() throws {
            let suiteName = "AccountMeetingSettingsTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let intervalKey = AppSettings.automaticScreenshotIntervalSecondsUserDefaultsKey
            let localeKey = AppSettings.transcriptionLocaleUserDefaultsKey

            // The values from before per-account settings belong to the first account opened.
            defaults.set(5, forKey: intervalKey)
            AppSettings.switchMeetingSettings(in: defaults)
            #expect(defaults.integer(forKey: intervalKey) == 5)
            defaults.set("en_US", forKey: localeKey)

            // Opening the account again keeps the values it set.
            AppSettings.switchMeetingSettings(in: defaults)
            #expect(defaults.integer(forKey: intervalKey) == 5)
            #expect(defaults.string(forKey: localeKey) == "en_US")
        }

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
