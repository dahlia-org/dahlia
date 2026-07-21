@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BatchLanguageDetectionCandidateResolverTests {
        @Test
        func allScopeDoesNotRestrictWhisperLanguages() {
            let identifiers = BatchLanguageDetectionCandidateResolver.languageIdentifiers(
                scope: .all,
                enabledLocaleIdentifiers: ["en_US", "ja_JP"],
                fallbackLocaleIdentifier: "fr_FR"
            )

            #expect(identifiers == nil)
        }

        @Test
        func selectedScopeNormalizesRegionsAndIncludesFallback() {
            let identifiers = BatchLanguageDetectionCandidateResolver.languageIdentifiers(
                scope: .selected,
                enabledLocaleIdentifiers: ["en_US", "en_GB", "ja_JP"],
                fallbackLocaleIdentifier: "fr_CA"
            )

            #expect(identifiers == ["en", "fr", "ja"])
        }

        @Test
        func selectedScopeAlwaysHasSelectedTranscriptionLanguage() {
            let identifiers = BatchLanguageDetectionCandidateResolver.languageIdentifiers(
                scope: .selected,
                enabledLocaleIdentifiers: [],
                fallbackLocaleIdentifier: "ja_JP"
            )

            #expect(identifiers == ["ja"])
        }

        @Test
        func selectedScopeMapsAppleLanguageCodesToWhisperTokens() {
            let identifiers = BatchLanguageDetectionCandidateResolver.languageIdentifiers(
                scope: .selected,
                enabledLocaleIdentifiers: ["nb_NO", "fil_PH", "jv_ID"],
                fallbackLocaleIdentifier: "en_US"
            )

            #expect(identifiers == ["en", "jw", "no", "tl"])
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
