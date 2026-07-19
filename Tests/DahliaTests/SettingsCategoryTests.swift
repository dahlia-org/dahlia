@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SettingsCategoryTests {
        @Test
        func categoriesAreOrderedByUserWorkflow() {
            #expect(SettingsCategory.allCases == [
                .general,
                .backups,
                .transcription,
                .screenshots,
                .calendar,
                .cloudStorage,
                .modelProvider,
                .aiSummary,
                .mcp,
                .instructions,
                .developer,
                .audioDiagnostics,
            ])
        }

        @Test
        func groupsContainEveryCategoryOnce() {
            let groupedCategories = SettingsGroup.allCases.flatMap(\.categories)
            #expect(groupedCategories == SettingsCategory.allCases)
        }

        @Test
        func technicalCategoriesUseUserFacingLabelsAndIdentifiers() {
            #expect(SettingsCategory.modelProvider.rawValue == "accounts")
            #expect(SettingsCategory.backups.label == L10n.backups)
            #expect(SettingsCategory.backups.systemImage == "externaldrive.badge.timemachine")
            #expect(SettingsCategory.modelProvider.label == L10n.aiConnection)
            #expect(SettingsCategory.cloudStorage.rawValue == "cloudStorage")
            #expect(SettingsCategory.cloudStorage.label == L10n.export)
            #expect(SettingsCategory.mcp.rawValue == "mcp")
            #expect(SettingsCategory.mcp.label == "MCP")
            #expect(SettingsCategory.mcp.systemImage == "network")
            #expect(SettingsCategory.audioDiagnostics.rawValue == "audioDiagnostics")
            #expect(SettingsCategory.audioDiagnostics.label == L10n.diagnostics)
        }

        @Test
        func advancedSettingsRemainAtTheEnd() {
            #expect(SettingsGroup.allCases.last == .advanced)
            #expect(SettingsGroup.advanced.categories == [.developer, .audioDiagnostics])
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
