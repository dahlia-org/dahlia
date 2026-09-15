import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SettingsCategoryTests {
        @Test
        func groupsContainEveryCategoryOnce() {
            let groupedCategories = SettingsGroup.allCases.flatMap(\.categories)
            let hiddenCategories: Set<SettingsCategory> = [
                .dahliaAccounts,
                .modelProvider,
                .aiSummary,
                .instructions,
                .mcp,
                .language,
                .appearance,
            ]
            let expectedCategories = SettingsCategory.allCases.filter { !hiddenCategories.contains($0) }

            #expect(groupedCategories.count == expectedCategories.count)
            #expect(Set(groupedCategories) == Set(expectedCategories))
        }

        @Test
        func everySelectionResolvesToAnAccessibleDestination() {
            #expect(SettingsNavigation.visibleSelection(.language) == .general)
            #expect(SettingsNavigation.visibleSelection(.appearance) == .general)
            #expect(SettingsNavigation.visibleSelection(.instructions) == .accountPreferences)
            #expect(SettingsNavigation.visibleSelection(.mcp) == .accountPreferences)
            #expect(SettingsNavigation.visibleSelection(.aiSummary) == .accountPreferences)
            #expect(SettingsNavigation.visibleSelection(.dahliaAccounts) == .accountsAndWorkspaces)
            #expect(SettingsNavigation.visibleSelection(.workspace) == .workspace)
            #expect(SettingsNavigation.visibleSelection(.modelProvider) == .macInference)
            #expect(SettingsNavigation.visibleSelection(.calendar) == .calendar)

            let visible = Set(SettingsGroup.allCases.flatMap(\.categories))
            for category in SettingsCategory.allCases {
                #expect(visible.contains(SettingsNavigation.visibleSelection(category)))
            }
        }

        @Test
        func searchFindsControlsAndDoesNotDependOnTechnicalCategoryNames() {
            #expect(SettingsCategory.general.matches(L10n.appLanguage))
            #expect(SettingsCategory.transcription.matches(L10n.batchAudioRetentionPeriod))
            #expect(SettingsCategory.liveSubtitles.matches(L10n.translationTargetLanguage))
            #expect(SettingsCategory.macInference.matches("  chatGPT \n "))
            #expect(SettingsCategory.cloudStorage.matches("google"))
            #expect(SettingsCategory.accountPreferences.matches(L10n.automaticRecordingProcessing))
            #expect(SettingsCategory.general.matches(" \n "))
            #expect(!SettingsCategory.general.matches("not-a-setting"))
            #expect(!SettingsCategory.macInference.matches("ChatGPT not-a-setting"))
        }

        @Test
        func savedSelectionDefaultsToGeneralAndNormalizesHiddenCategories() throws {
            let suiteName = "SettingsCategoryTests.\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            #expect(SettingsNavigation.savedSelection(in: defaults) == .general)

            defaults.set(SettingsCategory.instructions.rawValue, forKey: SettingsNavigation.selectedCategoryDefaultsKey)

            #expect(SettingsNavigation.savedSelection(in: defaults) == .accountPreferences)

            defaults.set(SettingsCategory.dahliaAccounts.rawValue, forKey: SettingsNavigation.selectedCategoryDefaultsKey)
            #expect(SettingsNavigation.savedSelection(in: defaults) == .accountsAndWorkspaces)
        }

        @Test
        func saveSelectionPersistsVisibleCategory() throws {
            let suiteName = "SettingsCategoryTests.\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            SettingsNavigation.saveSelection(.cloudStorage, in: defaults)

            #expect(defaults.string(forKey: SettingsNavigation.selectedCategoryDefaultsKey) == SettingsCategory.cloudStorage.rawValue)
        }

        @Test
        func storedCategoryIdentifiersStayStable() {
            #expect(SettingsCategory.modelProvider.rawValue == "accounts")
            #expect(SettingsCategory.accountsAndWorkspaces.rawValue == "accountsAndWorkspaces")
            #expect(SettingsCategory.dahliaAccounts.rawValue == "dahliaAccounts")
            #expect(SettingsCategory.workspace.rawValue == "workspace")
            #expect(SettingsCategory.liveSubtitles.rawValue == "liveSubtitles")
            #expect(SettingsCategory.cloudStorage.rawValue == "cloudStorage")
            #expect(SettingsCategory.mcp.rawValue == "mcp")
            #expect(SettingsCategory.audioDiagnostics.rawValue == "audioDiagnostics")
        }

        @Test
        func transcriptionModesKeepStoredIdentifiers() {
            #expect(TranscriptionMode.realtime.rawValue == "realtime")
            #expect(TranscriptionMode.batch.rawValue == "batch")
        }

        @Test
        func settingsCopyNamesTheInstructionAndHidesEnvironmentVariables() {
            let instructionName = "Weekly review"

            #expect(L10n.deleteInstructionConfirmation(instructionName).contains(instructionName))
            #expect(L10n.aiAccountDescription.contains(L10n.localAccount))
            #expect(L10n.aiAccountSettingsDescription.contains(L10n.localAccount))
            #expect(!L10n.googleOAuthClientIDOverrideDescription.contains("GOOGLE_CLIENT_ID"))
            #expect(!L10n.googleOAuthClientSecretOverrideDescription.contains("GOOGLE_CLIENT_SECRET"))
        }
    }
#endif
