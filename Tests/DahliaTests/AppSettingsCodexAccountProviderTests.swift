@testable import Dahlia

#if canImport(Testing)
    import Testing

    @Suite(.serialized)
    @MainActor
    struct AppSettingsCodexAccountProviderTests {
        @Test
        func providerChangesClearDatabricksProfileButRepeatedSelectionDoesNot() {
            let settings = AppSettings.shared
            let originalProvider = settings.codexAccountProviderRawValue
            let originalProfile = settings.codexDatabricksProfile
            defer {
                settings.codexAccountProviderRawValue = originalProvider
                settings.codexDatabricksProfile = originalProfile
            }

            settings.codexAccountProviderRawValue = AIAccountProvider.chatGPTSubscription.rawValue
            settings.codexDatabricksProfile = "DEFAULT"

            settings.codexAccountProvider = .databricks
            #expect(settings.codexDatabricksProfile.isEmpty)

            settings.codexDatabricksProfile = "WORK"
            settings.codexAccountProvider = .chatGPTSubscription
            #expect(settings.codexDatabricksProfile.isEmpty)

            settings.codexDatabricksProfile = "KEEP"
            settings.codexAccountProvider = .chatGPTSubscription
            #expect(settings.codexDatabricksProfile == "KEEP")
        }
    }
#endif
