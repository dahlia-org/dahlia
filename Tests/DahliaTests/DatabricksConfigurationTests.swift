@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct DatabricksConfigurationTests {
        @Test
        func profileSelectionUsesOnlyRegisteredCLIProfiles() {
            #expect(AppSettings.resolvedDatabricksProfileSelection(current: "", availableProfiles: []).isEmpty)
            #expect(AppSettings.resolvedDatabricksProfileSelection(current: "CUSTOM", availableProfiles: []).isEmpty)
            #expect(
                AppSettings.resolvedDatabricksProfileSelection(
                    current: "MISSING",
                    availableProfiles: ["DEV", "WORK"]
                ) == "DEV"
            )
            #expect(
                AppSettings.resolvedDatabricksProfileSelection(
                    current: " WORK ",
                    availableProfiles: ["DEV", "WORK"]
                ) == "WORK"
            )
        }

        @Test
        func oauthConfigurationRequiresWorkspaceAndCLIProfile() {
            let settings = AppSettings.shared
            let previousProviderRawValue = settings.llmProviderRawValue
            let previousWorkspaceID = settings.llmDatabricksWorkspaceID
            let previousAuthenticationTypeRawValue = settings.llmDatabricksAuthenticationTypeRawValue
            let previousProfile = settings.llmDatabricksProfile
            defer {
                settings.llmProviderRawValue = previousProviderRawValue
                settings.llmDatabricksWorkspaceID = previousWorkspaceID
                settings.llmDatabricksAuthenticationTypeRawValue = previousAuthenticationTypeRawValue
                settings.llmDatabricksProfile = previousProfile
            }

            settings.llmProvider = .databricks
            settings.llmDatabricksWorkspaceID = "1234567890123456"
            settings.llmDatabricksAuthenticationType = .oauthCLI
            settings.llmDatabricksProfile = "WORK"
            #expect(settings.isLLMConfigComplete)

            settings.llmDatabricksProfile = "  "
            #expect(!settings.isLLMConfigComplete)
        }
    }
#endif
