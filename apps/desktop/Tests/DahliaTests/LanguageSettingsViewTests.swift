#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct LanguageSettingsViewTests {
        @Test
        func localeOptionsRetainOnlyTheirOwnSelection() {
            let enabledLocales = [Locale(identifier: "en_US")]
            let transcriptionOptions = LanguageSettingsView.localeOptions(
                from: enabledLocales,
                including: "ja_JP"
            )
            let liveSubtitleOptions = LanguageSettingsView.localeOptions(
                from: enabledLocales,
                including: "fr_FR"
            )

            #expect(Set(transcriptionOptions.map(\.identifier)) == ["en_US", "ja_JP"])
            #expect(Set(liveSubtitleOptions.map(\.identifier)) == ["en_US", "fr_FR"])
        }
    }
#endif
