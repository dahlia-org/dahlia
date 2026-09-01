import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SettingsCategoryTests {
        @Test
        func groupsContainEveryCategoryOnce() {
            let groupedCategories = SettingsGroup.allCases.flatMap(\.categories)
            let hiddenCategories: Set<SettingsCategory> = [.dahliaAccounts, .vault, .modelProvider, .instructions, .mcp]
            let expectedCategories = SettingsCategory.allCases.filter { !hiddenCategories.contains($0) }

            #expect(SettingsCategory.allCases == [
                .accountsAndVaults,
                .general,
                .dahliaAccounts,
                .language,
                .appearance,
                .vault,
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
            #expect(!groupedCategories.contains(.vault))
            #expect(SettingsGroup.allCases.last == .advanced)
            #expect(SettingsGroup.app.categories == [
                .accountsAndVaults,
                .general,
                .language,
                .appearance,
                .permissions,
                .backups,
                .search,
            ])
            #expect(SettingsGroup.meetings.label == L10n.meetings)
            #expect(SettingsGroup.meetings.categories == [.transcription, .liveSubtitles, .screenshots, .aiSummary])
            #expect(SettingsGroup.advanced.categories == [.betaFeatures, .developer, .audioDiagnostics])
            #expect(!AppSettings.defaultCustomerIntelligenceBetaEnabled)
            #expect(!AppSettings.defaultConversationAnalyticsBetaEnabled)
            #expect(DetailTab.allCases == [.summary, .notes, .screenshots, .transcript, .conversationAnalytics])
        }

        @Test
        func hiddenSelectionsResolveToVisibleSettings() {
            #expect(SettingsNavigation.visibleSelection(.instructions) == .aiSummary)
            #expect(SettingsNavigation.visibleSelection(.mcp) == .aiSummary)
            #expect(SettingsNavigation.visibleSelection(.dahliaAccounts) == .accountsAndVaults)
            #expect(SettingsNavigation.visibleSelection(.vault) == .accountsAndVaults)
            #expect(SettingsNavigation.visibleSelection(.modelProvider) == .accountsAndVaults)
            #expect(SettingsNavigation.visibleSelection(.calendar) == .calendar)
        }

        @Test
        func savedSelectionDefaultsToGeneralAndNormalizesHiddenCategories() throws {
            let suiteName = "SettingsCategoryTests.\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            #expect(SettingsNavigation.savedSelection(in: defaults) == .general)

            defaults.set(SettingsCategory.instructions.rawValue, forKey: SettingsNavigation.selectedCategoryDefaultsKey)

            #expect(SettingsNavigation.savedSelection(in: defaults) == .aiSummary)

            defaults.set(SettingsCategory.dahliaAccounts.rawValue, forKey: SettingsNavigation.selectedCategoryDefaultsKey)
            #expect(SettingsNavigation.savedSelection(in: defaults) == .accountsAndVaults)
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
            #expect(SettingsCategory.accountsAndVaults.rawValue == "accountsAndVaults")
            #expect(SettingsCategory.accountsAndVaults.label == L10n.accountsAndVaults)
            #expect(SettingsCategory.accountsAndVaults.systemImage == "person.2")
            #expect(SettingsCategory.dahliaAccounts.rawValue == "dahliaAccounts")
            #expect(SettingsCategory.dahliaAccounts.label == L10n.dahliaAccount)
            #expect(SettingsCategory.dahliaAccounts.systemImage == "person.crop.circle")
            #expect(SettingsCategory.vault.rawValue == "vault")
            #expect(SettingsCategory.vault.label == L10n.vault)
            #expect(SettingsCategory.vault.systemImage == "externaldrive")
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
            #expect(SettingsCategory.aiSummary.label == L10n.summary)
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
            #expect(L10n.aiAccountDescription.localizedCaseInsensitiveContains(L10n.currentVault))
            #expect(L10n.aiAccountSettingsDescription.localizedCaseInsensitiveContains(L10n.currentVault))
            #expect(!L10n.deleteInstructionWarning.isEmpty)
            #expect(!L10n.googleOAuthClientIDOverrideDescription.contains("GOOGLE_CLIENT_ID"))
            #expect(!L10n.googleOAuthClientSecretOverrideDescription.contains("GOOGLE_CLIENT_SECRET"))
            #expect(!L10n.developerSettingsDescription.isEmpty)
            #expect(!L10n.restoreAppDefaults.isEmpty)
        }
    }
#endif
