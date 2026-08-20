#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct LiveSubtitleLocaleSettingTests {
        @Test
        func migrationCopiesTheExistingTranscriptionLocaleOnlyOnce() throws {
            let suiteName = "LiveSubtitleLocaleSettingTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set("en_US", forKey: AppSettings.transcriptionLocaleUserDefaultsKey)

            AppSettings.migrateLiveSubtitleLocaleSetting(in: defaults)
            #expect(defaults.string(forKey: AppSettings.liveSubtitleLocaleUserDefaultsKey) == "en_US")

            defaults.set("ja_JP", forKey: AppSettings.liveSubtitleLocaleUserDefaultsKey)
            defaults.set("fr_FR", forKey: AppSettings.transcriptionLocaleUserDefaultsKey)
            AppSettings.migrateLiveSubtitleLocaleSetting(in: defaults)
            #expect(defaults.string(forKey: AppSettings.liveSubtitleLocaleUserDefaultsKey) == "ja_JP")
        }
    }
#endif
