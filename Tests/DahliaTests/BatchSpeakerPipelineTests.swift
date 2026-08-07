@preconcurrency import AVFoundation
import Foundation
import GRDB
import os
@testable import Dahlia

// swiftlint:disable file_length

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
    // swiftlint:disable:next type_body_length
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
        func missingSpeakerAssetsHaveActionableFailureReasonAndDiagnosticStage() async throws {
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
            let diagnostics = SpeakerAnalysisDiagnosticProbe()
            let analyzer = BatchSpeakerAnalysisService(
                extractorFactory: {
                    throw SpeakerModelAssetError.missingFile("segmentation.mlmodelc")
                },
                errorReporter: { _, context in
                    diagnostics.record(context)
                }
            )

            let analysis = try await store.withVerifiedTranscribableSegments(sessionId: fixture.session.id) { verified in
                try await analyzer.analyze(verifiedSegments: verified, recordingStartTime: fixture.session.startedAt)
            }

            #expect(analysis.sources.count == 1)
            #expect(analysis.sources.first?.audioSource == .microphone)
            #expect(analysis.sources.first?.failureReason == .modelAssetsUnavailable)
            #expect(analysis.sources.first?.speakers.isEmpty == true)
            #expect(diagnostics.context?["source"] == "batchSpeakerAnalysis")
            #expect(diagnostics.context?["stage"] == "extractorInitialization")
        }

        @Test
        func missingSpeakerAssetsPersistFailureWhileTranscriptStillCompletes() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "SpeakerAssetsMissingPersistence",
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
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                recordingAudioStore: store,
                speechRecognizer: SpeakerPipelineRecognizer(),
                speakerAnalyzerFactory: {
                    BatchSpeakerAnalysisService(
                        extractorFactory: {
                            throw SpeakerModelAssetError.missingFile("segmentation.mlmodelc")
                        },
                        errorReporter: { _, _ in }
                    )
                },
                speakerIdentificationEnabledProvider: { true },
                onStateChange: { _ in }
            )

            await coordinator.enqueue(sessionId: fixture.session.id)
            try await waitForCompletion(fixture)

            let persisted = try await fixture.database.dbQueue.read { db in
                try (
                    TranscriptSegmentRecord.fetchCount(db),
                    SpeakerAnalysisRecord.fetchOne(db)?.failureReason,
                    RecordingSessionRecord.fetchOne(db, key: fixture.session.id)?.batchCompletedAt
                )
            }
            #expect(persisted.0 == 1)
            #expect(persisted.1 == SpeakerMatchUnknownReason.modelAssetsUnavailable.rawValue)
            #expect(persisted.2 != nil)
        }

        @Test
        func cancellationDoesNotProduceFailedSpeakerAnalysis() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "SpeakerAnalysisCancellation",
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
                CancelledSpeakerExtractor()
            })

            await #expect(throws: CancellationError.self) {
                try await store.withVerifiedTranscribableSegments(sessionId: fixture.session.id) { verified in
                    try await analyzer.analyze(
                        verifiedSegments: verified,
                        recordingStartTime: fixture.session.startedAt
                    )
                }
            }
        }

        @Test
        func sameSpeakerAcrossSessionsPersistsOneCluster() async throws {
            let fixture = try await MultiSessionSpeakerTestFixture.make(name: "D24SpeakerRows")
            #expect(fixture.sessions.map(\.offsetSeconds) == [0, 10, 20])
            for index in fixture.sessions.indices {
                _ = try fixture.persistSpeakerAnalysis(sessionIndex: index)
            }

            let counts = try await fixture.database.dbQueue.read { db in
                try (
                    MeetingSpeakerRecord.fetchCount(db),
                    MeetingSpeakerClusterRecord.fetchCount(db),
                    MeetingSpeakerClusterMemberRecord.fetchCount(db)
                )
            }

            #expect(counts == (fixture.sessions.count, 1, fixture.sessions.count))
        }

        @Test
        func sameSpeakerAcrossSessionsReceivesOneRepositoryOrdinal() async throws {
            let fixture = try await MultiSessionSpeakerTestFixture.make(name: "D24SpeakerOrdinals")
            for index in fixture.sessions.indices {
                _ = try fixture.persistSpeakerAnalysis(sessionIndex: index)
            }

            let page = try MeetingRepository(dbQueue: fixture.database.dbQueue).fetchTranscriptPage(
                forMeetingId: fixture.meetingId,
                direction: .latest,
                limit: fixture.sessions.count
            )

            #expect(page.segments.compactMap(\.speakerIdentity?.ordinal) == [1, 1, 1])
        }

        @Test
        func differentSpeakersAcrossSessionsRemainSeparateClusters() async throws {
            let fixture = try await MultiSessionSpeakerTestFixture.make(
                name: "D24NoFalseMerge",
                sessionDurations: [10, 10]
            )
            _ = try fixture.persistSpeakerAnalysis(sessionIndex: 0, representativeValues: fixture.unitVector(axis: 0))
            _ = try fixture.persistSpeakerAnalysis(sessionIndex: 1, representativeValues: fixture.unitVector(axis: 1))

            let clusterCount = try await fixture.database.dbQueue.read { db in
                try MeetingSpeakerClusterRecord.fetchCount(db)
            }

            #expect(clusterCount == 2)
        }

        @Test
        func differentEmbeddingSpacesRemainSeparateClusters() async throws {
            let fixture = try await MultiSessionSpeakerTestFixture.make(
                name: "D24EmbeddingSpaces",
                sessionDurations: [10, 10]
            )
            _ = try fixture.persistSpeakerAnalysis(
                sessionIndex: 0,
                embeddingSpace: fixture.embeddingSpace(assetFingerprint: "space-a")
            )
            _ = try fixture.persistSpeakerAnalysis(
                sessionIndex: 1,
                embeddingSpace: fixture.embeddingSpace(assetFingerprint: "space-b")
            )

            let state = try await fixture.database.dbQueue.read { db in
                try (
                    MeetingSpeakerClusterRecord.fetchCount(db),
                    Set(MeetingSpeakerClusterRecord.fetchAll(db).map(\.embeddingSpaceId)).count
                )
            }

            #expect(state == (2, 2))
        }

        @Test
        func differentAudioSourcesRemainSeparateClusters() async throws {
            let fixture = try await MultiSessionSpeakerTestFixture.make(
                name: "D24AudioSources",
                sessionDurations: [10, 10]
            )
            _ = try fixture.persistSpeakerAnalysis(sessionIndex: 0, audioSource: .microphone)
            _ = try fixture.persistSpeakerAnalysis(sessionIndex: 1, audioSource: .system)

            let clusters = try await fixture.database.dbQueue.read { db in
                try MeetingSpeakerClusterRecord.order(Column("audioSource")).fetchAll(db)
            }

            #expect(clusters.count == 2)
            #expect(Set(clusters.map(\.audioSource)) == [.microphone, .system])
        }

        @Test
        func retranscriptionPreservesClusterContactAssignment() async throws {
            let fixture = try await MultiSessionSpeakerTestFixture.make(
                name: "D24RetranscriptionAssignment",
                sessionDurations: [10]
            )
            let first = try fixture.persistSpeakerAnalysis(sessionIndex: 0)
            let now = fixture.sessions[0].startedAt.addingTimeInterval(20)
            let contactId = UUID.v7()
            let vaultId = try await fixture.database.dbQueue.write { db in
                let meeting = try #require(try MeetingRecord.fetchOne(db, key: fixture.meetingId))
                try ContactRecord(
                    id: contactId,
                    vaultId: meeting.vaultId,
                    email: "alice@example.com",
                    displayName: "Alice",
                    revision: 1,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
                return meeting.vaultId
            }
            _ = try await MeetingRepository(dbQueue: fixture.database.dbQueue).manuallyAssignSpeaker(
                meetingSpeakerId: first.speakerId,
                contactId: contactId,
                vaultId: vaultId,
                expectedRevision: 1,
                now: now
            )
            let originalClusterId = try await fixture.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE recording_sessions SET batchLastAttemptAt = ? WHERE id = ?",
                    arguments: [now.addingTimeInterval(1), fixture.sessions[0].id]
                )
                return try #require(
                    try UUID.fetchOne(
                        db,
                        sql: "SELECT clusterId FROM meeting_speaker_cluster_members WHERE meetingSpeakerId = ?",
                        arguments: [first.speakerId]
                    )
                )
            }

            let retranscribed = try fixture.persistSpeakerAnalysis(sessionIndex: 0, identityVariant: 1)

            let preserved = try await fixture.database.dbQueue.read { db in
                let member = try #require(
                    try MeetingSpeakerClusterMemberRecord.fetchOne(db, key: retranscribed.speakerId)
                )
                let stableAssignment = try #require(
                    try SpeakerClusterContactAssignmentRecord.fetchOne(db, key: member.clusterId)
                )
                let projectedAssignment = try #require(
                    try SpeakerContactAssignmentRecord.fetchOne(db, key: retranscribed.speakerId)
                )
                return (member.clusterId, stableAssignment, projectedAssignment)
            }

            #expect(retranscribed.speakerId != first.speakerId)
            #expect(preserved.0 == originalClusterId)
            #expect(preserved.1.contactId == contactId)
            #expect(preserved.1.origin == .manual)
            #expect(preserved.2.contactId == contactId)
            #expect(preserved.2.origin == .manual)
        }

        @Test
        func mapSpeakersUsesSessionRelativeTimebaseAcrossNonzeroOffsets() async throws {
            let fixture = try await MultiSessionSpeakerTestFixture.make(name: "D24SpeakerTimebase")
            #expect(fixture.sessions.map(\.offsetSeconds) == [0, 10, 20])
            var mappedSpeakerIds: [UUID] = []
            var displayedSeconds: [TimeInterval] = []
            for index in fixture.sessions.indices {
                let session = fixture.sessions[index]
                let segment = TranscriptSegment(
                    sessionId: session.id,
                    startTime: session.startedAt.addingTimeInterval(1.25),
                    endTime: session.startedAt.addingTimeInterval(1.75),
                    text: "Speaker session \(index + 1)",
                    isConfirmed: true,
                    speakerLabel: RecordingAudioSource.microphone.speakerLabel
                )
                let speakerAnalysis = fixture.makeSpeakerAnalysis(
                    sessionIndex: index,
                    relativeStartSeconds: 1.25,
                    relativeEndSeconds: 1.75
                )
                let assignments = BatchTranscriptionCoordinator.mapSpeakers(
                    to: [segment],
                    analysis: speakerAnalysis.analysis,
                    recordingStartTime: session.startedAt
                )
                try mappedSpeakerIds.append(#require(assignments[segment.id]))
                displayedSeconds.append(Formatters.elapsedSeconds(
                    at: segment.startTime,
                    sessionId: segment.sessionId,
                    sessions: fixture.sessions.map(RecordingSessionTimeline.init),
                    fallbackTimeBase: fixture.recordingStartTime
                ))
            }

            // Mapping remains session-local; cross-session identity is projected later through persisted clusters.
            #expect(Set(mappedSpeakerIds).count == fixture.sessions.count)

            // Timebase safety invariant: offsetSeconds is applied only when projecting display elapsed time.
            #expect(displayedSeconds == [1.25, 11.25, 21.25])
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
        ) async throws -> BatchProcessingOutput.SpeakerAnalysis {
            probe.recordAnalysisCall()
            let speaker = BatchProcessingOutput.Speaker(
                id: .v7(),
                localSpeakerId: "speaker-0",
                representative: SpeakerEmbedding(space: testSpeakerSpace, values: unitSpeakerVector),
                representativeQuality: 1,
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

    private struct CancelledSpeakerExtractor: SpeakerEmbeddingExtractor {
        func extract(from _: MemoryMappedAudioSampleSource) async throws -> [MeetingSpeakerEvidence] {
            throw CancellationError()
        }
    }

    private final class SpeakerAnalysisDiagnosticProbe: Sendable {
        private let state = OSAllocatedUnfairLock<[String: String]?>(initialState: nil)

        var context: [String: String]? { state.withLock(\.self) }

        func record(_ context: [String: String]) {
            state.withLock { $0 = context }
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
        sampleRate: 16000,
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
