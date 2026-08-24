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
            let summary = GeneralSettingsView.languageSelectionSummaryParts(
                identifiers: ["en", "fr", "ja"],
                locale: Locale(identifier: "en")
            )
            let emptySummary = GeneralSettingsView.languageSelectionSummaryParts(
                identifiers: [],
                locale: Locale(identifier: "en")
            )

            #expect(summary.names == ["English", "French"])
            #expect(summary.remainingCount == 1)
            #expect(emptySummary.names.isEmpty)
            #expect(emptySummary.remainingCount == 0)
        }
    }
#endif
