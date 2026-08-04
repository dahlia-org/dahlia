@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SettingsCategoryTests {
        @Test
        func categoriesAreOrderedByUserWorkflow() {
            #expect(SettingsCategory.allCases == [
                .general,
                .permissions,
                .transcription,
                .screenshots,
                .calendar,
                .cloudStorage,
                .modelProvider,
                .aiSummary,
                .mcp,
                .betaFeatures,
                .developer,
            ])
        }

        @Test
        func groupsContainEveryCategoryOnce() {
            let groupedCategories = SettingsGroup.allCases.flatMap(\.categories)
            let expectedCategories = SettingsCategory.allCases

            #expect(groupedCategories == expectedCategories)
        }

        @Test
        func hiddenInstructionsSelectionOpensAISummarySettings() {
            #expect(SettingsNavigation.visibleSelection(rawValue: "instructions") == .aiSummary)
            #expect(SettingsNavigation.visibleSelection(rawValue: "calendar") == .calendar)
        }

        @Test
        func technicalCategoriesUseUserFacingLabelsAndIdentifiers() {
            #expect(SettingsCategory.modelProvider.rawValue == "accounts")
            #expect(SettingsCategory.permissions.label == L10n.permissions)
            #expect(SettingsCategory.permissions.systemImage == "hand.raised")
            #expect(SettingsCategory.modelProvider.label == L10n.aiConnection)
            #expect(SettingsCategory.cloudStorage.rawValue == "cloudStorage")
            #expect(SettingsCategory.cloudStorage.label == L10n.export)
            #expect(SettingsCategory.mcp.rawValue == "mcp")
            #expect(SettingsCategory.mcp.label == "MCP")
            #expect(SettingsCategory.mcp.systemImage == "network")
            #expect(SettingsCategory.betaFeatures.label == L10n.betaFeatures)
            #expect(SettingsCategory.betaFeatures.systemImage == "testtube.2")
        }

        @Test
        func advancedSettingsRemainAtTheEnd() {
            #expect(SettingsGroup.allCases.last == .advanced)
            #expect(SettingsGroup.app.categories == [.general, .permissions])
            #expect(SettingsGroup.recording.categories == [.transcription, .screenshots])
            #expect(SettingsGroup.advanced.categories == [.betaFeatures, .developer])
            #expect(!AppSettings.defaultCustomerIntelligenceBetaEnabled)
            #expect(!AppSettings.defaultConversationAnalyticsBetaEnabled)
            #expect(DetailTab.allCases == [.summary, .notes, .screenshots, .transcript, .conversationAnalytics])
        }

        @Test
        func conversationAnalysisTabRemainsBehindItsBetaSetting() {
            #expect(DetailTab.availableTabs(isConversationAnalysisEnabled: false) == [
                .summary,
                .notes,
                .screenshots,
                .transcript,
            ])
            #expect(DetailTab.availableTabs(isConversationAnalysisEnabled: true) == DetailTab.allCases)
        }

        @Test
        func settingsFeedbackCopyNamesTheActionAndAffectedInstruction() {
            let instructionName = "Weekly review"

            #expect(!L10n.copied.isEmpty)
            #expect(!L10n.changesSaveAutomatically.isEmpty)
            #expect(!L10n.instructionTitleRequired.isEmpty)
            #expect(L10n.deleteInstructionConfirmation(instructionName).contains(instructionName))
            #expect(!L10n.deleteInstructionWarning.isEmpty)
        }

        @Test
        func developerSettingsCopyUsesUserFacingTerms() {
            #expect(!L10n.googleOAuthClientIDOverrideDescription.contains("GOOGLE_CLIENT_ID"))
            #expect(!L10n.googleOAuthClientSecretOverrideDescription.contains("GOOGLE_CLIENT_SECRET"))
            #expect(!L10n.developerSettingsDescription.isEmpty)
            #expect(!L10n.restoreAppDefaults.isEmpty)
        }
    }
#endif
