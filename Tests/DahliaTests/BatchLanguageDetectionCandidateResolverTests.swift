import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BatchLanguageDetectionCandidateResolverTests {
        @Test
        func allScopeUsesAppleSupportedLanguages() {
            let candidates = BatchLanguageDetectionCandidateResolver.candidates(
                scope: .all,
                enabledLocaleIdentifiers: ["en_US", "ja_JP"],
                supportedLocales: locales("en_US", "fr_FR", "ja_JP")
            )

            #expect(candidates.snapshot.identifierSet == ["en", "fr", "ja"])
            #expect(candidates.snapshot.scope == .all)
        }

        @Test
        func selectedScopeNormalizesEnabledRegions() {
            let candidates = BatchLanguageDetectionCandidateResolver.candidates(
                scope: .selected,
                enabledLocaleIdentifiers: ["en_US", "en_GB", "ja_JP"],
                supportedLocales: locales("en_US", "fr_CA", "ja_JP")
            )

            #expect(candidates.snapshot.identifierSet == ["en", "ja"])
        }

        @Test
        func selectedScopeCanBeEmpty() {
            let candidates = BatchLanguageDetectionCandidateResolver.candidates(
                scope: .selected,
                enabledLocaleIdentifiers: [],
                supportedLocales: locales("en_US", "ja_JP")
            )

            #expect(candidates.snapshot.languageIdentifiers.isEmpty)
            #expect(candidates.locales.isEmpty)
        }

        @Test
        func selectedScopeMapsAppleLanguageCodesToWhisperTokens() {
            let candidates = BatchLanguageDetectionCandidateResolver.candidates(
                scope: .selected,
                enabledLocaleIdentifiers: ["nb_NO", "fil_PH", "jv_ID"],
                supportedLocales: locales("en_US", "fil_PH", "jv_ID", "nb_NO")
            )

            #expect(candidates.snapshot.identifierSet == ["jw", "no", "tl"])
        }

        @Test
        func filtersWhisperUnsupportedLanguagesAndDeduplicatesRegions() {
            let candidates = BatchLanguageDetectionCandidateResolver.candidates(
                scope: .all,
                enabledLocaleIdentifiers: [],
                supportedLocales: locales("en_US", "en_GB", "zz_ZZ", "ja_JP")
            )

            #expect(candidates.snapshot.identifierSet == ["en", "ja"])
            #expect(candidates.locales.map(\.identifier) == ["en_US", "ja_JP"])
        }

        @Test
        func candidateSnapshotRoundTripsScopeAndSortedIdentifiers() throws {
            let snapshot = BatchLanguageDetectionCandidateSnapshot(
                scope: .all,
                languageIdentifiers: ["ja", "en"]
            )

            let decoded = try BatchLanguageDetectionCandidateSnapshot.decode(snapshot.encoded())

            #expect(decoded == snapshot)
            #expect(decoded.languageIdentifiers == ["en", "ja"])
        }

        private func locales(_ identifiers: String...) -> [Locale] {
            identifiers.map { Locale(identifier: $0) }
        }
    }

    struct TranscriptionLanguageScopeTests {
        @Test(arguments: [
            ("all", Set(["en_US"]), TranscriptionLanguageScope.all),
            ("selected", Set<String>(), TranscriptionLanguageScope.selected),
            ("", Set<String>(), TranscriptionLanguageScope.all),
            ("", Set(["en_US", "ja_JP"]), TranscriptionLanguageScope.selected),
            ("unknown", Set<String>(), TranscriptionLanguageScope.all),
        ])
        func resolvesExplicitAndLegacySettings(
            storedRawValue: String,
            enabledLocaleIdentifiers: Set<String>,
            expected: TranscriptionLanguageScope
        ) {
            #expect(AppSettings.resolvedTranscriptionLanguageScope(
                storedRawValue: storedRawValue,
                enabledLocaleIdentifiers: enabledLocaleIdentifiers
            ) == expected)
        }
    }
#endif
