import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct QuickRecordingMeetingTitleTests {
        @Test
        func titleIncludesLocalTimestamp() throws {
            let timeZone = try #require(TimeZone(secondsFromGMT: 9 * 60 * 60))

            let title = QuickRecordingMeetingTitle.make(
                at: Date(timeIntervalSince1970: 0),
                timeZone: timeZone
            )

            #expect(title.hasSuffix("1970-01-01 09:00:00"))
        }

        @Test
        func stringsAreLocalizedInEnglishAndJapanese() throws {
            let english = try #require(localizationBundle(language: "en"))
            let japanese = try #require(localizationBundle(language: "ja"))
            let timestamp = "2026-08-15 12:34:56"

            #expect(english.localizedString(forKey: "Quick Recording", value: nil, table: nil) == "Quick Recording")
            #expect(japanese.localizedString(forKey: "Quick Recording", value: nil, table: nil) == "クイック録音")
            #expect(localizedMeetingName(timestamp, bundle: english, locale: Locale(identifier: "en")) ==
                "Quick recording 2026-08-15 12:34:56")
            #expect(localizedMeetingName(timestamp, bundle: japanese, locale: Locale(identifier: "ja")) ==
                "クイック録音 2026-08-15 12:34:56")
        }

        private func localizationBundle(language: String) -> Bundle? {
            Bundle.appModule.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
        }

        private func localizedMeetingName(_ timestamp: String, bundle: Bundle, locale: Locale) -> String {
            String(
                format: bundle.localizedString(forKey: "Quick recording %@", value: nil, table: nil),
                locale: locale,
                timestamp
            )
        }
    }
#endif
