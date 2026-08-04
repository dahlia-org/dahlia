import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SettingsNavigationTests {
        @Test(arguments: [
            ("backups", SettingsCategory.general),
            ("liveSubtitles", SettingsCategory.transcription),
            ("audioDiagnostics", SettingsCategory.developer),
            ("instructions", SettingsCategory.aiSummary),
        ])
        func removedSelectionsMigrate(rawValue: String, expected: SettingsCategory) {
            #expect(SettingsNavigation.visibleSelection(rawValue: rawValue) == expected)
        }

        @Test
        func unknownSelectionFallsBackToGeneral() {
            #expect(SettingsNavigation.visibleSelection(rawValue: "removed-in-future") == .general)
        }
    }
#endif
