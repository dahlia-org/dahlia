import Foundation
@testable import Dahlia

#if canImport(Testing)
    import AppKit
    import SwiftUI
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
                .recordingStopDetection,
            ]
            let expectedCategories = SettingsCategory.allCases.filter { !hiddenCategories.contains($0) }

            #expect(groupedCategories.count == expectedCategories.count)
            #expect(Set(groupedCategories) == Set(expectedCategories))
        }

        @Test
        @MainActor
        func sidebarGroupsAreNotCollapsible() throws {
            var selection = SettingsCategory.general
            let host = NSHostingView(rootView: SettingsSidebarView(
                selection: Binding(get: { selection }, set: { selection = $0 }),
                onReturnToApp: {}
            ))
            host.frame = NSRect(x: 0, y: 0, width: 280, height: 700)
            host.layoutSubtreeIfNeeded()
            let outline = try #require(outlineView(in: host))
            #expect(
                outline.numberOfRows == SettingsGroup.allCases.count
                    + SettingsGroup.allCases.flatMap(\.categories).count
                    + 2
            )

            #expect((0 ..< outline.numberOfRows).allSatisfy { row in
                guard let item = outline.item(atRow: row) else { return true }
                return !outline.isExpandable(item)
            })
        }

        @Test
        func everySelectionResolvesToAnAccessibleDestination() {
            #expect(SettingsNavigation.visibleSelection(.language) == .general)
            #expect(SettingsNavigation.visibleSelection(.appearance) == .general)
            #expect(SettingsNavigation.visibleSelection(.recordingStopDetection) == .general)
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
            #expect(SettingsCategory.general.matches(L10n.automaticRecordingStop))
            #expect(SettingsCategory.general.matches(L10n.externalMicrophoneEchoCancellation))
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

            defaults.set(SettingsCategory.recordingStopDetection.rawValue, forKey: SettingsNavigation.selectedCategoryDefaultsKey)
            #expect(SettingsNavigation.savedSelection(in: defaults) == .general)
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
            #expect(SettingsCategory.recordingStopDetection.rawValue == "recordingStopDetection")
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

        @MainActor
        private func outlineView(in view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            return view.subviews.lazy.compactMap { outlineView(in: $0) }.first
        }
    }
#endif
