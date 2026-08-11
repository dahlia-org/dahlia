import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct TranscriptTranslationServiceTests {
        @Test
        func batchTranslationUsesOneSessionAndChunksAtOneHundredRequests() async throws {
            let probe = BatchTranslationProbe()
            let service = makeService(probe: probe)
            let requests = (0 ..< 101).map { index in
                TranscriptTranslationService.BatchRequest(
                    id: .v7(),
                    text: "segment-\(index)",
                    sourceLocaleIdentifier: "en_US"
                )
            }

            let translations = try await service.translateBatch(requests, to: "ja")

            #expect(translations.count == 101)
            #expect(await probe.sessionCount == 1)
            #expect(await probe.chunkSizes == [100, 1])
        }

        @Test
        func batchTranslationCreatesOneSessionPerSourceLanguage() async throws {
            let probe = BatchTranslationProbe()
            let service = makeService(probe: probe)
            let requests = [
                TranscriptTranslationService.BatchRequest(
                    id: .v7(),
                    text: "English",
                    sourceLocaleIdentifier: "en_US"
                ),
                TranscriptTranslationService.BatchRequest(
                    id: .v7(),
                    text: "Français",
                    sourceLocaleIdentifier: "fr_FR"
                ),
            ]

            let translations = try await service.translateBatch(requests, to: "ja")

            #expect(translations.count == 2)
            #expect(await probe.sessionCount == 2)
            #expect(await probe.sourceLanguageIdentifiers.count == 2)
        }

        @Test
        func failedChunkDoesNotPreventLaterChunkFromTranslating() async throws {
            let probe = BatchTranslationProbe(failingCallNumbers: [1])
            let service = makeService(probe: probe)
            let requests = (0 ..< 101).map { index in
                TranscriptTranslationService.BatchRequest(
                    id: .v7(),
                    text: "segment-\(index)",
                    sourceLocaleIdentifier: "en_US"
                )
            }

            let translations = try await service.translateBatch(requests, to: "ja")

            #expect(translations.count == 1)
            #expect(await probe.chunkSizes == [100, 1])
        }

        @Test
        func cancellationFromBatchSessionPropagates() async {
            let probe = BatchTranslationProbe(cancels: true)
            let service = makeService(probe: probe)
            let request = TranscriptTranslationService.BatchRequest(
                id: .v7(),
                text: "segment",
                sourceLocaleIdentifier: "en_US"
            )

            await #expect(throws: CancellationError.self) {
                _ = try await service.translateBatch([request], to: "ja")
            }
        }

        private func makeService(probe: BatchTranslationProbe) -> TranscriptTranslationService {
            TranscriptTranslationService(
                batchSessionFactory: { source, _ in
                    await probe.makeSession(sourceLanguageIdentifier: source.maximalIdentifier)
                },
                languagePairSupportProvider: { _, _ in true }
            )
        }
    }

    private actor BatchTranslationProbe {
        private let failingCallNumbers: Set<Int>
        private let cancels: Bool
        private(set) var sessionCount = 0
        private(set) var chunkSizes: [Int] = []
        private(set) var sourceLanguageIdentifiers: Set<String> = []
        private var callCount = 0

        init(failingCallNumbers: Set<Int> = [], cancels: Bool = false) {
            self.failingCallNumbers = failingCallNumbers
            self.cancels = cancels
        }

        func makeSession(sourceLanguageIdentifier: String) -> any TranscriptBatchTranslationSession {
            sessionCount += 1
            sourceLanguageIdentifiers.insert(sourceLanguageIdentifier)
            return ProbeBatchTranslationSession(probe: self)
        }

        func translate(
            _ requests: [TranscriptBatchTranslationInput]
        ) throws -> [TranscriptBatchTranslationOutput] {
            callCount += 1
            chunkSizes.append(requests.count)
            if cancels {
                throw CancellationError()
            }
            if failingCallNumbers.contains(callCount) {
                throw BatchTranslationProbeError.forcedFailure
            }
            return requests.map {
                TranscriptBatchTranslationOutput(
                    targetText: "translated-\($0.sourceText)",
                    clientIdentifier: $0.clientIdentifier
                )
            }
        }
    }

    private struct ProbeBatchTranslationSession: TranscriptBatchTranslationSession {
        let probe: BatchTranslationProbe

        func translations(
            from requests: [TranscriptBatchTranslationInput]
        ) async throws -> [TranscriptBatchTranslationOutput] {
            try await probe.translate(requests)
        }
    }

    private enum BatchTranslationProbeError: Error {
        case forcedFailure
    }
#endif
