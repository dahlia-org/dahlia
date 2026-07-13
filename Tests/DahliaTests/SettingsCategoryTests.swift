@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SettingsCategoryTests {
        @Test
        func debugCategoryIsLastAndUsesDebugPresentation() {
            #expect(SettingsCategory.allCases.last == .audioDiagnostics)
            #expect(SettingsCategory.audioDiagnostics.label == L10n.debug)
            #expect(SettingsCategory.audioDiagnostics.systemImage == "ladybug")
        }
    }
#endif
