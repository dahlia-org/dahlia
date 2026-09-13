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
                .workspace,
                .modelProvider,
                .aiSummary,
                .instructions,
                .mcp,
                .language,
                .appearance,
            ]
            let expectedCategories = SettingsCategory.allCases.filter { !hiddenCategories.contains($0) }

            #expect(SettingsCategory.allCases == [
                .accountsAndWorkspaces,
                .accountPreferences,
                .macInference,
                .general,
                .dahliaAccounts,
                .language,
                .appearance,
                .workspace,
                .permissions,
                .backups,
                .search,
                .transcription,
                .liveSubtitles,
                .screenshots,
                .calendar,
                .cloudStorage,
                .modelProvider,
                .aiSummary,
                .mcp,
                .instructions,
                .betaFeatures,
                .developer,
                .audioDiagnostics,
            ])
            #expect(groupedCategories.count == expectedCategories.count)
            #expect(Set(groupedCategories) == Set(expectedCategories))
            #expect(!groupedCategories.contains(.instructions))
            #expect(!groupedCategories.contains(.mcp))
            #expect(!groupedCategories.contains(.dahliaAccounts))
            #expect(!groupedCategories.contains(.workspace))
            #expect(!groupedCategories.contains(.aiSummary))
            #expect(SettingsGroup.allCases.last == .advanced)
            #expect(SettingsGroup.app.categories == [
                .general,
                .transcription,
                .liveSubtitles,
                .screenshots,
                .macInference,
                .permissions,
            ])
            #expect(SettingsGroup.account.categories == [.accountPreferences])
            #expect(SettingsGroup.app.label == L10n.thisMac)
            #expect(SettingsGroup.data.categories == [.accountsAndWorkspaces, .backups])
            #expect(SettingsGroup.advanced.categories == [.search, .betaFeatures, .developer, .audioDiagnostics])
            #expect(!AppSettings.defaultConversationAnalyticsBetaEnabled)
            #expect(DetailTab.allCases == [.summary, .notes, .screenshots, .transcript, .conversationAnalytics])
        }

        @Test
        func hiddenSelectionsResolveToVisibleSettings() {
            #expect(SettingsNavigation.visibleSelection(.language) == .general)
            #expect(SettingsNavigation.visibleSelection(.appearance) == .general)
            #expect(SettingsNavigation.visibleSelection(.instructions) == .accountPreferences)
            #expect(SettingsNavigation.visibleSelection(.mcp) == .accountPreferences)
            #expect(SettingsNavigation.visibleSelection(.aiSummary) == .accountPreferences)
            #expect(SettingsNavigation.visibleSelection(.dahliaAccounts) == .accountsAndWorkspaces)
            #expect(SettingsNavigation.visibleSelection(.workspace) == .accountsAndWorkspaces)
            #expect(SettingsNavigation.visibleSelection(.modelProvider) == .macInference)
            #expect(SettingsNavigation.visibleSelection(.calendar) == .calendar)
        }

        @Test
        func searchFindsControlsAndDoesNotDependOnTechnicalCategoryNames() {
            #expect(SettingsCategory.general.matches(L10n.appLanguage))
            #expect(SettingsCategory.transcription.matches(L10n.batchAudioRetentionPeriod))
            #expect(SettingsCategory.liveSubtitles.matches(L10n.translationTargetLanguage))
            #expect(SettingsCategory.macInference.matches("  chatGPT \n "))
            #expect(SettingsCategory.cloudStorage.matches("google"))
            #expect(SettingsCategory.accountPreferences.matches(L10n.imageAnalysisLanguages))
            #expect(SettingsCategory.general.matches(" \n "))
            #expect(!SettingsCategory.general.matches("not-a-setting"))
            #expect(!SettingsCategory.macInference.matches("ChatGPT not-a-setting"))
        }

        @Test
        func everySavedCategoryResolvesToAnAccessibleDestination() {
            let visible = Set(SettingsGroup.allCases.flatMap(\.categories))
            for category in SettingsCategory.allCases {
                #expect(visible.contains(SettingsNavigation.visibleSelection(category)))
            }
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
            #expect(SettingsCategory.accountsAndWorkspaces.label == L10n.accountsAndWorkspaces)
            #expect(SettingsCategory.accountsAndWorkspaces.systemImage == "person.2")
            #expect(SettingsCategory.dahliaAccounts.rawValue == "dahliaAccounts")
            #expect(SettingsCategory.dahliaAccounts.label == L10n.dahliaAccount)
            #expect(SettingsCategory.dahliaAccounts.systemImage == "person.crop.circle")
            #expect(SettingsCategory.workspace.rawValue == "workspace")
            #expect(SettingsCategory.workspace.label == L10n.workspace)
            #expect(SettingsCategory.workspace.systemImage == "externaldrive")
            #expect(SettingsCategory.backups.label == L10n.backups)
            #expect(SettingsCategory.permissions.label == L10n.permissions)
            #expect(SettingsCategory.permissions.systemImage == "hand.raised")
            #expect(SettingsCategory.backups.systemImage == "externaldrive.badge.timemachine")
            #expect(SettingsCategory.search.label == L10n.search)
            #expect(SettingsCategory.search.systemImage == "magnifyingglass")
            #expect(SettingsCategory.language.label == L10n.language)
            #expect(SettingsCategory.language.systemImage == "globe")
            #expect(SettingsCategory.modelProvider.label == L10n.modelProvider)
            #expect(SettingsCategory.modelProvider.systemImage == "sparkles")
            #expect(SettingsCategory.aiSummary.label == L10n.transcriptionAndSummary)
            #expect(SettingsCategory.aiSummary.systemImage == "list.bullet.clipboard")
            #expect(SettingsCategory.liveSubtitles.rawValue == "liveSubtitles")
            #expect(SettingsCategory.liveSubtitles.label == L10n.liveSubtitles)
            #expect(SettingsCategory.liveSubtitles.systemImage == "captions.bubble")
            #expect(SettingsCategory.cloudStorage.rawValue == "cloudStorage")
            #expect(SettingsCategory.cloudStorage.label == L10n.export)
            #expect(SettingsCategory.mcp.rawValue == "mcp")
            #expect(SettingsCategory.mcp.label == "MCP")
            #expect(SettingsCategory.mcp.systemImage == "network")
            #expect(SettingsCategory.audioDiagnostics.rawValue == "audioDiagnostics")
            #expect(SettingsCategory.audioDiagnostics.label == L10n.diagnostics)
            #expect(SettingsCategory.betaFeatures.label == L10n.betaFeatures)
            #expect(SettingsCategory.betaFeatures.systemImage == "testtube.2")
        }

        @Test
        func transcriptionModesKeepStoredIdentifiersAndUseUserFacingLabels() {
            #expect(TranscriptionMode.allCases == [.realtime, .batch])
            #expect(TranscriptionMode.realtime.rawValue == "realtime")
            #expect(TranscriptionMode.batch.rawValue == "batch")
            #expect(TranscriptionMode.realtime.displayName == L10n.realtimeTranscription)
            #expect(TranscriptionMode.batch.displayName == L10n.batchTranscription)
        }

        @Test
        func settingsCopyNamesTheInstructionAndHidesEnvironmentVariables() {
            let instructionName = "Weekly review"

            #expect(!L10n.copied.isEmpty)
            #expect(!L10n.changesSaveAutomatically.isEmpty)
            #expect(!L10n.instructionTitleRequired.isEmpty)
            #expect(L10n.deleteInstructionConfirmation(instructionName).contains(instructionName))
            #expect(L10n.aiAccountDescription.contains(L10n.localAccount))
            #expect(L10n.aiAccountSettingsDescription.contains(L10n.localAccount))
            #expect(!L10n.deleteInstructionWarning.isEmpty)
            #expect(!L10n.googleOAuthClientIDOverrideDescription.contains("GOOGLE_CLIENT_ID"))
            #expect(!L10n.googleOAuthClientSecretOverrideDescription.contains("GOOGLE_CLIENT_SECRET"))
            #expect(!L10n.developerSettingsDescription.isEmpty)
            #expect(!L10n.restoreAppDefaults.isEmpty)
        }
    }
#endif
