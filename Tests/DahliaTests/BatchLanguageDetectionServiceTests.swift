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
                languageDetector: detector
            )

            #expect(locale.identifier == "en_GB")
        }

        @Test
        func usesKnownFallbackWhenRecordedLocalesDoNotMatch() async throws {
            let detector = BatchLanguageDetectorStub(behavior: .detection("en"))

            let locale = try await BatchLanguageDetectionService.resolveLocale(
                audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                recordedLocaleIdentifiers: ["ja_JP"],
                supportedLocales: [Locale(identifier: "en_GB"), Locale(identifier: "en_US")],
                languageDetector: detector
            )

            #expect(locale.identifier == "en_US")
        }

        @Test
        func usesIdentifierOrderWhenLanguageHasNoKnownFallback() async throws {
            let detector = BatchLanguageDetectorStub(behavior: .detection("fr"))

            let locale = try await BatchLanguageDetectionService.resolveLocale(
                audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                recordedLocaleIdentifiers: ["ja_JP"],
                supportedLocales: [Locale(identifier: "fr_FR"), Locale(identifier: "fr_CA")],
                languageDetector: detector
            )

            #expect(locale.identifier == "fr_CA")
        }

        @Test
        func rejectsDetectedLanguageWithoutAppleLocale() async {
            let detector = BatchLanguageDetectorStub(behavior: .detection("fr"))

            await #expect(throws: BatchSpeechTranscriberError.self) {
                _ = try await BatchLanguageDetectionService.resolveLocale(
                    audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                    recordedLocaleIdentifiers: ["ja_JP"],
                    supportedLocales: [Locale(identifier: "ja_JP"), Locale(identifier: "en_US")],
                    languageDetector: detector
                )
            }
        }

        @Test
        func rejectsEmptyDetectionResult() async {
            let detector = BatchLanguageDetectorStub(behavior: .detection(""))

            await #expect(throws: BatchSpeechTranscriberError.self) {
                _ = try await BatchLanguageDetectionService.resolveLocale(
                    audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                    recordedLocaleIdentifiers: ["ja_JP"],
                    supportedLocales: [Locale(identifier: "ja_JP")],
                    languageDetector: detector
                )
            }
        }

        @Test
        func wrapsDetectorFailure() async {
            let detector = BatchLanguageDetectorStub(behavior: .failure)

            do {
                _ = try await BatchLanguageDetectionService.resolveLocale(
                    audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                    recordedLocaleIdentifiers: ["ja_JP"],
                    supportedLocales: [Locale(identifier: "ja_JP")],
                    languageDetector: detector
                )
                Issue.record("Expected language detection to fail")
            } catch {
                #expect(error.localizedDescription == L10n.batchLanguageDetectionFailed)
                #expect(!error.localizedDescription.contains("/Users/"))
            }
        }

        @Test
        func distinguishesModelPreparationFailureWithoutExposingDetails() async {
            let detector = BatchLanguageDetectorStub(behavior: .modelPreparationFailure)

            do {
                _ = try await BatchLanguageDetectionService.resolveLocale(
                    audioURL: URL(fileURLWithPath: "/Users/alice/private/meeting.caf"),
                    recordedLocaleIdentifiers: ["ja_JP"],
                    supportedLocales: [Locale(identifier: "ja_JP")],
                    languageDetector: detector
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
                    languageDetector: detector
                )
            }
        }
    }
#endif
