@preconcurrency import AVFoundation
import Foundation
import GRDB
import os
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
    struct BatchSpeakerPipelineTests {
        @Test
        func speakerIdentificationDefaultsOff() {
            #expect(!AppSettings.defaultSpeakerIdentificationEnabled)
        }

        @Test
        func toggleOffDoesNotConstructAnalyzerOrPersistSpeakerRows() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "SpeakerToggleOff",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 0.01,
                retainAudioAfterBatch: true
            )
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let probe = SpeakerPipelineProbe()
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                speechRecognizer: SpeakerPipelineRecognizer(),
                speakerAnalyzerFactory: {
                    probe.recordFactoryCall()
                    return SpeakerPipelineAnalyzer(probe: probe)
                },
                speakerIdentificationEnabledProvider: { false },
                onStateChange: { _ in }
            )

            await coordinator.enqueue(sessionId: fixture.session.id)
            try await waitForCompletion(fixture)

            let counts = try await fixture.database.dbQueue.read { db in
                try (
                    TranscriptSegmentRecord.fetchCount(db),
                    SpeakerAnalysisRecord.fetchCount(db),
                    MeetingSpeakerRecord.fetchCount(db)
                )
            }
            #expect(counts == (1, 0, 0))
            #expect(probe.factoryCallCount == 0)
            #expect(probe.analysisCallCount == 0)
        }

        @Test
        func toggleOnAnalyzesInsideExactlyOneVerifiedReadLeaseAndMapsTranscript() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "SpeakerSingleLease",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 0.01,
                retainAudioAfterBatch: true
            )
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let probe = SpeakerPipelineProbe()
            let store = try RecordingAudioStore(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                onReadLeaseStateChange: { probe.recordLeaseState($0) }
            )
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                recordingAudioStore: store,
                speechRecognizer: SpeakerPipelineRecognizer(),
                speakerAnalyzerFactory: {
                    probe.recordFactoryCall()
                    return SpeakerPipelineAnalyzer(probe: probe)
                },
                speakerIdentificationEnabledProvider: { true },
                onStateChange: { _ in }
            )

            await coordinator.enqueue(sessionId: fixture.session.id)
            try await waitForCompletion(fixture)

            let persisted = try await fixture.database.dbQueue.read { db in
                let transcript = try #require(try TranscriptSegmentRecord.fetchOne(db))
                return try (
                    transcript,
                    SpeakerAnalysisRecord.fetchCount(db),
                    MeetingSpeakerRecord.fetchCount(db),
                    SpeakerDiarizationSpanRecord.fetchCount(db)
                )
            }
            #expect(probe.leaseEntryCount == 1)
            #expect(probe.leaseExitCount == 1)
            #expect(probe.analysisCallCount == 1)
            #expect(probe.allAnalysisCallsWereInsideLease)
            #expect(persisted.0.meetingSpeakerId != nil)
            #expect((persisted.1, persisted.2, persisted.3) == (1, 1, 1))
        }

        @Test
        func missingSpeakerAssetsDegradeToAnalysisFailedWithoutThrowing() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "SpeakerAssetsMissing",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 0.01,
                retainAudioAfterBatch: true
            )
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let store = try RecordingAudioStore(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL
            )
            let analyzer = BatchSpeakerAnalysisService(extractorFactory: {
                MissingAssetsSpeakerExtractor()
            })

            let analysis = try await store.withVerifiedTranscribableSegments(sessionId: fixture.session.id) { verified in
                await analyzer.analyze(verifiedSegments: verified, recordingStartTime: fixture.session.startedAt)
            }

            #expect(analysis.sources.count == 1)
            #expect(analysis.sources.first?.audioSource == .microphone)
            #expect(analysis.sources.first?.failureReason == .analysisFailed)
            #expect(analysis.sources.first?.speakers.isEmpty == true)
        }

        private func waitForCompletion(_ fixture: BatchAudioTestFixture) async throws {
            let completed = await pollUntil {
                (try? fixture.database.dbQueue.read { db in
                    try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)?.batchCompletedAt != nil
                }) == true
            }
            #expect(completed)
        }
    }

    private struct SpeakerPipelineRecognizer: BatchSpeechRecognizing {
        func recognize(audioURL _: URL, locale _: Locale) async -> [BatchSpeechRecognition] {
            recognitions
        }

        func recognize(audioSlices _: [BatchSpeechAudioSlice], locale _: Locale) async -> [BatchSpeechRecognition] {
            recognitions
        }

        private var recognitions: [BatchSpeechRecognition] {
            [BatchSpeechRecognition(startSeconds: 0, endSeconds: 0.005, text: "Speaker")]
        }
    }

    private struct SpeakerPipelineAnalyzer: BatchSpeakerAnalyzing {
        let probe: SpeakerPipelineProbe

        func analyze(
            verifiedSegments _: [RecordingAudioStore.VerifiedSegment],
            recordingStartTime _: Date
        ) async -> BatchProcessingOutput.SpeakerAnalysis {
            probe.recordAnalysisCall()
            let speaker = BatchProcessingOutput.Speaker(
                id: .v7(),
                localSpeakerId: "speaker-0",
                representative: SpeakerEmbedding(space: testSpeakerSpace, values: unitSpeakerVector),
                representativeSource: .diarization,
                profileUpdateEligible: true,
                exemplars: [],
                spans: [SpeakerDiarizationSpan(speakerID: "speaker-0", startTimeSeconds: 0, endTimeSeconds: 0.01)]
            )
            return BatchProcessingOutput.SpeakerAnalysis(sources: [
                BatchProcessingOutput.SourceAnalysis(
                    id: .v7(),
                    audioSource: .microphone,
                    embeddingSpace: testSpeakerSpace,
                    speakers: [speaker],
                    failureReason: nil
                ),
            ])
        }
    }

    private struct MissingAssetsSpeakerExtractor: SpeakerEmbeddingExtractor {
        func extract(from _: MemoryMappedAudioSampleSource) async throws -> [MeetingSpeakerEvidence] {
            throw SpeakerModelAssetError.missingFile("segmentation.mlmodelc")
        }
    }

    private final class SpeakerPipelineProbe: Sendable {
        private struct State {
            var factoryCallCount = 0
            var analysisCallCount = 0
            var leaseEntryCount = 0
            var leaseExitCount = 0
            var isInsideLease = false
            var allAnalysisCallsWereInsideLease = true
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        var factoryCallCount: Int { state.withLock(\.factoryCallCount) }
        var analysisCallCount: Int { state.withLock(\.analysisCallCount) }
        var leaseEntryCount: Int { state.withLock(\.leaseEntryCount) }
        var leaseExitCount: Int { state.withLock(\.leaseExitCount) }
        var allAnalysisCallsWereInsideLease: Bool { state.withLock(\.allAnalysisCallsWereInsideLease) }

        func recordFactoryCall() {
            state.withLock { $0.factoryCallCount += 1 }
        }

        func recordAnalysisCall() {
            state.withLock {
                $0.analysisCallCount += 1
                $0.allAnalysisCallsWereInsideLease = $0.allAnalysisCallsWereInsideLease && $0.isInsideLease
            }
        }

        func recordLeaseState(_ isInsideLease: Bool) {
            state.withLock {
                $0.isInsideLease = isInsideLease
                if isInsideLease {
                    $0.leaseEntryCount += 1
                } else {
                    $0.leaseExitCount += 1
                }
            }
        }
    }

    private let testSpeakerSpace = SpeakerEmbeddingSpace(
        provider: "Test",
        modelName: "speaker",
        revision: "1",
        assetFingerprint: "fingerprint",
        fluidAudioVersion: "0.15.5",
        dimensionCount: SpeakerEmbeddingValidation.dimensionCount,
        sampleRate: 16_000,
        preprocessing: "mono-float32",
        excludesOverlap: true,
        normalization: "L2 unit norm",
        similarityDefinition: "cosine dot product"
    )

    private let unitSpeakerVector: [Float] = {
        var values = [Float](repeating: 0, count: SpeakerEmbeddingValidation.dimensionCount)
        values[0] = 1
        return values
    }()
#endif
