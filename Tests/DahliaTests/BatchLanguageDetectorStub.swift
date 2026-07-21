import Foundation
@testable import Dahlia

#if canImport(Testing)
    struct BatchLanguageDetectorStub: BatchLanguageDetecting {
        enum Behavior: Sendable {
            case detection(String)
            case failure
            case modelPreparationFailure
            case cancellation
        }

        let behavior: Behavior

        func detectLanguage(audioURL _: URL) async throws -> String {
            switch behavior {
            case let .detection(languageIdentifier):
                languageIdentifier
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
