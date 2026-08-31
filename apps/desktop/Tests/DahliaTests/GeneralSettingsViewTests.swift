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

        @Test
        func dahliaAccountStatusCopyIsNotCloudSpecific() {
            #expect(!L10n.dahliaNotSignedIn.localizedCaseInsensitiveContains("cloud"))
            #expect(!L10n.dahliaSignedInAs("User").localizedCaseInsensitiveContains("cloud"))
        }

        @Test
        func dahliaCloudActionShowsComingSoonOnlyWhenUnconfigured() {
            #expect(DahliaServerSignInView.cloudActionTitle(isConfigured: true) == L10n.signInToDahliaCloud)
            #expect(DahliaServerSignInView.cloudActionTitle(isConfigured: false) == L10n.dahliaCloudComingSoon)
        }

        @Test
        func manuallyEnteredServerUsesFixedClientID() throws {
            let configuration = try #require(DahliaServerSignInView.serverConfiguration(
                urlString: "https://server.example.com"
            ))

            #expect(configuration.clientID == DahliaCloudConfiguration.defaultClientID)
        }
    }
#endif
