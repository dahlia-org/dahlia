#if canImport(Testing)
    import Combine
    import Foundation
    import Testing
    @testable import Dahlia

    struct AccountMeetingSettingsTests {
        @Test
        func switchingAccountsRestoresEachAccountsMeetingSettings() throws {
            let suiteName = "AccountMeetingSettingsTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let intervalKey = AppSettings.automaticScreenshotIntervalSecondsUserDefaultsKey
            let localeKey = AppSettings.transcriptionLocaleUserDefaultsKey
            let dahlia = CodexRuntimeProvider.dahlia(connectionID: UUID())

            // The values from before per-account settings belong to the first account opened.
            defaults.set(5, forKey: intervalKey)
            AppSettings.switchMeetingSettings(to: .local, in: defaults)
            #expect(defaults.integer(forKey: intervalKey) == 5)

            // A new account starts from the previous account's values.
            AppSettings.switchMeetingSettings(to: dahlia, in: defaults)
            #expect(defaults.integer(forKey: intervalKey) == 5)
            defaults.set(30, forKey: intervalKey)
            defaults.set("en_US", forKey: localeKey)

            AppSettings.switchMeetingSettings(to: .local, in: defaults)
            #expect(defaults.integer(forKey: intervalKey) == 5)
            // A value the account never set returns to the default, which observers see too.
            #expect(defaults.object(forKey: localeKey) == nil)
            #expect(defaults.transcriptionLocale == Locale.current.identifier)

            AppSettings.switchMeetingSettings(to: dahlia, in: defaults)
            #expect(defaults.integer(forKey: intervalKey) == 30)
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
