import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SettingsCategoryTests {
        @Test
        func groupsContainEveryCategoryOnce() {
            let groupedCategories = SettingsGroup.allCases.flatMap(\.categories)
            let expectedCategories = SettingsCategory.allCases.filter { $0 != .instructions && $0 != .mcp }

            #expect(groupedCategories == expectedCategories)
            #expect(!groupedCategories.contains(.instructions))
            #expect(!groupedCategories.contains(.mcp))
        }

        @Test
        func hiddenSelectionsOpenAISummarySettings() {
            #expect(SettingsNavigation.visibleSelection(.instructions) == .aiSummary)
            #expect(SettingsNavigation.visibleSelection(.mcp) == .aiSummary)
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
            #expect(SettingsCategory.vault.rawValue == "vault")
            #expect(SettingsCategory.liveSubtitles.rawValue == "liveSubtitles")
            #expect(SettingsCategory.cloudStorage.rawValue == "cloudStorage")
            #expect(SettingsCategory.mcp.rawValue == "mcp")
            #expect(SettingsCategory.audioDiagnostics.rawValue == "audioDiagnostics")
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

            #expect(L10n.deleteInstructionConfirmation(instructionName).contains(instructionName))
            #expect(!L10n.googleOAuthClientIDOverrideDescription.contains("GOOGLE_CLIENT_ID"))
            #expect(!L10n.googleOAuthClientSecretOverrideDescription.contains("GOOGLE_CLIENT_SECRET"))
        }
    }
#endif
