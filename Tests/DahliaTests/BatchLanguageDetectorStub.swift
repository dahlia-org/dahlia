import Foundation
@testable import Dahlia

#if canImport(Testing)
    extension BatchLanguageDetectionOutcome {
        static func confidentDetection(_ languageIdentifier: String) -> Self {
            .detected(
                languageIdentifier: languageIdentifier,
                logProbability: Float(log(0.9))
            )
        }
    }

    struct BatchLanguageDetectorStub: BatchLanguageDetecting {
        enum Behavior: Sendable {
            case detection(String)
            case outcome(BatchLanguageDetectionOutcome)
            case failure
            case modelPreparationFailure
            case cancellation
        }

        let behavior: Behavior

        func detectLanguage(
            audioURL _: URL,
            allowedLanguageIdentifiers _: Set<String>?
        ) async throws -> BatchLanguageDetectionOutcome {
            switch behavior {
            case let .detection(languageIdentifier):
                .confidentDetection(languageIdentifier)
            case let .outcome(outcome):
                outcome
            case .failure:
                throw CocoaError(.fileReadUnknown)
            case .modelPreparationFailure:
                throw BatchLanguageDetectorError.modelPreparationFailed
            case .cancellation:
                throw CancellationError()
            }
        }

        func unload() async {}
    }
#endif
