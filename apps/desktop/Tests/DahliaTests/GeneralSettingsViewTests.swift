#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct GeneralSettingsViewTests {
        @Test
        func languageSelectionDraftCommitsOnlyWhenRequested() {
            var savedScope: AppLanguageScope?
            var savedIdentifiers: Set<String>?
            var draft = AppLanguageSelectionDraft(
                scope: .selected,
                enabledLanguageIdentifiers: ["en", "ja"]
            )

            draft.scope = .all
            draft.enabledLanguageIdentifiers = ["fr"]

            #expect(savedScope == nil)
            #expect(savedIdentifiers == nil)

            draft.commit { scope, identifiers in
                savedScope = scope
                savedIdentifiers = identifiers
            }

            #expect(savedScope == .all)
            #expect(savedIdentifiers == ["fr"])
        }

        @Test
        func languageSelectionSummaryIsBounded() {
            let summary = AppLanguageSelectionRow.summaryParts(
                identifiers: ["en", "fr", "ja"],
                locale: Locale(identifier: "en")
            )
            let emptySummary = AppLanguageSelectionRow.summaryParts(
                identifiers: [],
                locale: Locale(identifier: "en")
            )

            #expect(summary.names == ["English", "French"])
            #expect(summary.remainingCount == 1)
            #expect(emptySummary.names.isEmpty)
            #expect(emptySummary.remainingCount == 0)
        }

        @Test
        func selectedLanguageDraftRejectsAnEmptySelection() {
            var didSave = false
            let draft = AppLanguageSelectionDraft(
                scope: .selected,
                enabledLanguageIdentifiers: []
            )

            draft.commit { _, _ in didSave = true }

            #expect(!draft.isValid)
            #expect(!didSave)
            #expect(AppLanguageSelectionDraft(scope: .all, enabledLanguageIdentifiers: []).isValid)
        }
    }
#endif
