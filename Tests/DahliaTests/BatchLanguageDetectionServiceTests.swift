import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BatchLanguageDetectionServiceTests {
        @Test
        func resolvesDetectedLanguageUsingRecordedRegionalVariant() async throws {
            let detector = BatchLanguageDetectorStub(behavior: .detection("en"))

            let locale = try await BatchLanguageDetectionService.resolveLocale(
                audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                recordedLocaleIdentifiers: ["ja_JP", "en_GB"],
                supportedLocales: [Locale(identifier: "en_US"), Locale(identifier: "en_GB")],
                languageDetector: detector,
                fallbackLocaleIdentifier: "ja_JP"
            )

            #expect(locale.locale.identifier == "en_GB")
        }

        @Test
        func usesKnownFallbackWhenRecordedLocalesDoNotMatch() async throws {
            let detector = BatchLanguageDetectorStub(behavior: .detection("en"))

            let locale = try await BatchLanguageDetectionService.resolveLocale(
                audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                recordedLocaleIdentifiers: ["ja_JP"],
                supportedLocales: [Locale(identifier: "en_GB"), Locale(identifier: "en_US")],
                languageDetector: detector,
                fallbackLocaleIdentifier: "ja_JP"
            )

            #expect(locale.locale.identifier == "en_US")
        }

        @Test
        func usesIdentifierOrderWhenLanguageHasNoKnownFallback() async throws {
            let detector = BatchLanguageDetectorStub(behavior: .detection("fr"))

            let locale = try await BatchLanguageDetectionService.resolveLocale(
                audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                recordedLocaleIdentifiers: ["ja_JP"],
                supportedLocales: [Locale(identifier: "fr_FR"), Locale(identifier: "fr_CA")],
                languageDetector: detector,
                fallbackLocaleIdentifier: "ja_JP"
            )

            #expect(locale.locale.identifier == "fr_CA")
        }

        @Test
        func resolvesWhisperNorwegianCodeToAppleBokmalLocale() async throws {
            let detector = BatchLanguageDetectorStub(behavior: .detection("no"))

            let resolution = try await BatchLanguageDetectionService.resolveLocale(
                audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                recordedLocaleIdentifiers: ["en_US", "nb_NO"],
                supportedLocales: [Locale(identifier: "en_US"), Locale(identifier: "nb_NO")],
                languageDetector: detector,
                fallbackLocaleIdentifier: "en_US"
            )

            #expect(resolution.locale.identifier == "nb_NO")
            #expect(resolution.fallback == nil)
        }

        @Test
        func rejectsFallbackLanguageWhenSelectedLocaleIsUnavailable() async {
            let detector = BatchLanguageDetectorStub(behavior: .detection("fr"))

            await #expect(throws: BatchSpeechTranscriberError.self) {
                _ = try await BatchLanguageDetectionService.resolveLocale(
                    audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                    recordedLocaleIdentifiers: ["fr_FR"],
                    supportedLocales: [Locale(identifier: "ja_JP")],
                    languageDetector: detector,
                    fallbackLocaleIdentifier: "en_US"
                )
            }
        }

        @Test
        func unsupportedDetectionFallsBackToSelectedLanguage() async throws {
            let detector = BatchLanguageDetectorStub(behavior: .detection("jw"))

            let locale = try await BatchLanguageDetectionService.resolveLocale(
                audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                recordedLocaleIdentifiers: ["ja_JP"],
                supportedLocales: [Locale(identifier: "ja_JP"), Locale(identifier: "en_US")],
                languageDetector: detector,
                fallbackLocaleIdentifier: "ja_JP"
            )

            #expect(locale.locale.identifier == "ja_JP")
            #expect(locale.fallback?.reason == .unsupportedLanguage)
        }

        @Test
        func detectedSelectedLanguageUsesSelectedRegionalLocale() async throws {
            let detector = BatchLanguageDetectorStub(behavior: .detection("en"))

            let locale = try await BatchLanguageDetectionService.resolveLocale(
                audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                recordedLocaleIdentifiers: ["en_US"],
                supportedLocales: [Locale(identifier: "en_US"), Locale(identifier: "en_GB")],
                languageDetector: detector,
                fallbackLocaleIdentifier: "en_GB"
            )

            #expect(locale.locale.identifier == "en_GB")
            #expect(locale.fallback == nil)
        }

        @Test
        func unsupportedDetectionUsesExplicitFallbackLocale() async throws {
            let detector = BatchLanguageDetectorStub(behavior: .detection("jw"))

            let locale = try await BatchLanguageDetectionService.resolveLocale(
                audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                recordedLocaleIdentifiers: ["en_US"],
                supportedLocales: [Locale(identifier: "ja_JP"), Locale(identifier: "en_US")],
                languageDetector: detector,
                fallbackLocaleIdentifier: "ja_JP"
            )

            #expect(locale.locale.identifier == "ja_JP")
            #expect(locale.fallback?.reason == .unsupportedLanguage)
        }

        @Test
        func lowConfidenceDetectionFallsBackToSelectedLanguage() async throws {
            let detector = BatchLanguageDetectorStub(
                behavior: .outcome(
                    .detected(
                        languageIdentifier: "jw",
                        logProbability: Float(log(0.2))
                    )
                )
            )

            let resolution = try await BatchLanguageDetectionService.resolveLocale(
                audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                recordedLocaleIdentifiers: ["ja_JP"],
                supportedLocales: [Locale(identifier: "en_US"), Locale(identifier: "ja_JP")],
                languageDetector: detector,
                fallbackLocaleIdentifier: "ja_JP"
            )

            #expect(resolution.locale.identifier == "ja_JP")
            #expect(resolution.fallback?.reason == .lowConfidence)
            #expect(abs((resolution.fallback?.topProbability ?? 0) - 0.2) < 0.001)
        }

        @Test
        func emptyDetectionResultFallsBackToSelectedLanguage() async throws {
            let detector = BatchLanguageDetectorStub(behavior: .detection(""))

            let resolution = try await BatchLanguageDetectionService.resolveLocale(
                audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                recordedLocaleIdentifiers: ["ja_JP"],
                supportedLocales: [Locale(identifier: "ja_JP")],
                languageDetector: detector,
                fallbackLocaleIdentifier: "ja_JP"
            )

            #expect(resolution.locale.identifier == "ja_JP")
            #expect(resolution.fallback?.reason == .detectionFailed)
        }

        @Test
        func detectorFailureFallsBackWithoutExposingDetails() async throws {
            let detector = BatchLanguageDetectorStub(behavior: .failure)

            let resolution = try await BatchLanguageDetectionService.resolveLocale(
                audioURL: URL(fileURLWithPath: "/Users/alice/private/meeting.caf"),
                recordedLocaleIdentifiers: ["ja_JP"],
                supportedLocales: [Locale(identifier: "ja_JP")],
                languageDetector: detector,
                fallbackLocaleIdentifier: "ja_JP"
            )

            #expect(resolution.locale.identifier == "ja_JP")
            #expect(resolution.fallback?.reason == .detectionFailed)
        }

        @Test
        func distinguishesModelPreparationFailureWithoutExposingDetails() async {
            let detector = BatchLanguageDetectorStub(behavior: .modelPreparationFailure)

            do {
                _ = try await BatchLanguageDetectionService.resolveLocale(
                    audioURL: URL(fileURLWithPath: "/Users/alice/private/meeting.caf"),
                    recordedLocaleIdentifiers: ["ja_JP"],
                    supportedLocales: [Locale(identifier: "ja_JP")],
                    languageDetector: detector,
                    fallbackLocaleIdentifier: "ja_JP"
                )
                Issue.record("Expected model preparation to fail")
            } catch {
                #expect(error.localizedDescription == L10n.batchLanguageModelPreparationFailed)
                #expect(!error.localizedDescription.contains("/Users/alice"))
            }
        }

        @Test
        func preservesCancellation() async {
            let detector = BatchLanguageDetectorStub(behavior: .cancellation)

            await #expect(throws: CancellationError.self) {
                _ = try await BatchLanguageDetectionService.resolveLocale(
                    audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                    recordedLocaleIdentifiers: ["ja_JP"],
                    supportedLocales: [Locale(identifier: "ja_JP")],
                    languageDetector: detector,
                    fallbackLocaleIdentifier: "ja_JP"
                )
            }
        }
    }
#endif
