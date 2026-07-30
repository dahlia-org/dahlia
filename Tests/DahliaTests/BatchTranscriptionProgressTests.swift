@preconcurrency import AVFoundation
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
    struct BatchTranscriptionProgressTests {
        @Test
        func reportsProgressFromCompletedCAFFileCount() async throws {
            let fixture = try makeFixture(name: "BatchFileProgress", duration: 0.0125)
            defer { fixture.removeFiles() }
            try await createSegmentedAutomaticRecording(fixture: fixture)
            let stateProbe = BatchProgressStateProbe()
            let coordinator = makeCoordinator(
                fixture: fixture,
                detector: ProgressLanguageDetector(detections: ["ja", "en"]),
                recognizer: ProgressSpeechRecognizer(),
                stateProbe: stateProbe
            )

            await coordinator.enqueue(sessionId: fixture.session.id)
            try await waitUntil { await stateProbe.didComplete }

            expectCompleteProgress(await stateProbe.reportedProgress(), totalFileCount: 2)
        }

        @Test
        func manualModeCompletesProgressForCAFWithoutAudioFrames() async throws {
            let fixture = try makeFixture(name: "BatchManualEmptyCAF", duration: 0.0125)
            defer { fixture.removeFiles() }
            try await createManualRecording(fixture: fixture, frameCounts: [])
            let stateProbe = BatchProgressStateProbe()
            let recognizer = ProgressSpeechRecognizer()
            let coordinator = makeCoordinator(
                fixture: fixture,
                detector: ProgressLanguageDetector(detections: []),
                recognizer: recognizer,
                stateProbe: stateProbe
            )

            await coordinator.enqueue(sessionId: fixture.session.id)
            try await waitUntil { await stateProbe.didComplete }

            #expect(await recognizer.callCount == 0)
            expectCompleteProgress(await stateProbe.reportedProgress(), totalFileCount: 1)
        }

        @Test
        func reportsEachManualMultiRangeCAFAsOneCompletedFile() async throws {
            let fixture = try makeFixture(name: "BatchManualMultiRangeProgress", duration: 0.015)
            defer { fixture.removeFiles() }
            try await createManualMultiRangeRecording(fixture: fixture)
            let stateProbe = BatchProgressStateProbe()
            let coordinator = makeCoordinator(
                fixture: fixture,
                detector: ProgressLanguageDetector(detections: []),
                recognizer: ProgressSpeechRecognizer(),
                stateProbe: stateProbe
            )

            await coordinator.enqueue(sessionId: fixture.session.id)
            try await waitUntil { await stateProbe.didComplete }

            expectCompleteProgress(await stateProbe.reportedProgress(), totalFileCount: 2)
        }

        @Test
        func slowProgressCallbackDoesNotDelayNextRecognition() async throws {
            let fixture = try makeFixture(name: "BatchProgressCallbackConcurrency", duration: 0.025)
            defer { fixture.removeFiles() }
            let fileCount = BatchTranscriptionConcurrency.appleSpeechMaximum * 2
            try await createSeparateAutomaticRecordingFiles(fixture: fixture, fileCount: fileCount)
            let stateProbe = SuspendingBatchProgressStateProbe()
            defer { Task { await stateProbe.releaseProgressCallback() } }
            let recognizer = ProgressSpeechRecognizer()
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                languageDetector: ProgressLanguageDetector(
                    detections: Array(repeating: "ja", count: fileCount)
                ),
                speechRecognizer: recognizer,
                supportedLocalesProvider: {
                    [Locale(identifier: "ja_JP")]
                },
                onStateChange: { update in
                    await stateProbe.record(update.state)
                }
            )

            await coordinator.enqueue(sessionId: fixture.session.id)
            try await waitUntil { await stateProbe.isHoldingProgressCallback }
            try await waitUntil { await recognizer.callCount == fileCount }
            let finalRunningState = BatchTranscriptionState.running(
                sessionId: fixture.session.id,
                progress: BatchTranscriptionProgress(completedFileCount: fileCount, totalFileCount: fileCount)
            )
            try await waitUntil {
                await coordinator.runningState(sessionId: fixture.session.id) == finalRunningState
            }
            #expect(await coordinator.runningState(sessionId: fixture.session.id) == finalRunningState)

            await stateProbe.releaseProgressCallback()
            try await waitUntil { await stateProbe.didComplete }
            expectCompleteProgress(await stateProbe.reportedProgress(), totalFileCount: fileCount)
        }

        private func makeFixture(name: String, duration: TimeInterval) throws -> BatchAudioTestFixture {
            try BatchAudioTestFixture(
                name: name,
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: duration,
                retainAudioAfterBatch: true
            )
        }

        private func makeCoordinator(
            fixture: BatchAudioTestFixture,
            detector: any BatchLanguageDetecting,
            recognizer: any BatchSpeechRecognizing,
            stateProbe: BatchProgressStateProbe
        ) -> BatchTranscriptionCoordinator {
            BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                languageDetector: detector,
                speechRecognizer: recognizer,
                supportedLocalesProvider: {
                    [Locale(identifier: "ja_JP"), Locale(identifier: "en_US")]
                },
                onStateChange: { update in
                    await stateProbe.record(update.state)
                }
            )
        }

        private func createSegmentedAutomaticRecording(fixture: BatchAudioTestFixture) async throws {
            try await createManualRecording(fixture: fixture, frameCounts: [80, 120])
            try await configureAutomaticLanguageDetection(fixture: fixture)
        }

        private func createManualRecording(
            fixture: BatchAudioTestFixture,
            frameCounts: [AVAudioFrameCount]
        ) async throws {
            let recorder = try makeRecorder(fixture: fixture, targetSegmentDuration: .milliseconds(5))
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            for frameCount in frameCounts {
                try writer.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: frameCount))
            }
            try await recorder.finish()
        }

        private func createSeparateAutomaticRecordingFiles(
            fixture: BatchAudioTestFixture,
            fileCount: Int
        ) async throws {
            let recorder = try makeRecorder(fixture: fixture, targetSegmentDuration: .seconds(60))
            for fileIndex in 0 ..< fileCount {
                let writer = try await recorder.beginRange(
                    source: .microphone,
                    locale: Locale(identifier: "ja_JP"),
                    at: fixture.now.addingTimeInterval(Double(fileIndex) * 0.005)
                )
                try writer.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 80))
                if fileIndex < fileCount - 1 {
                    try await recorder.endRangeForReconfiguration(source: .microphone)
                }
            }
            try await recorder.finish()
            try await configureAutomaticLanguageDetection(
                fixture: fixture,
                candidates: BatchLanguageDetectionCandidateSnapshot(
                    scope: .selected,
                    languageIdentifiers: ["ja"],
                    localeIdentifiers: ["ja_JP"]
                )
            )
            let recordedFileCount = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchCount(db)
            }
            #expect(recordedFileCount == fileCount)
        }

        private func createManualMultiRangeRecording(fixture: BatchAudioTestFixture) async throws {
            let recorder = try makeRecorder(fixture: fixture, targetSegmentDuration: .seconds(60))
            let firstWriter = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            try firstWriter.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 80))
            try await recorder.rotateRange(
                source: .microphone,
                locale: Locale(identifier: "en_US")
            )
            try firstWriter.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 80))
            try await recorder.endRangeForReconfiguration(source: .microphone)
            let secondWriter = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now.addingTimeInterval(0.01)
            )
            try secondWriter.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 80))
            try await recorder.finish()

            let rangeCounts = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord
                    .order(Column("segmentIndex").asc)
                    .fetchAll(db)
                    .map { segment in
                        try RecordingAudioSegmentRangeRecord
                            .filter(Column("audioSegmentId") == segment.id)
                            .fetchCount(db)
                    }
            }
            #expect(rangeCounts == [2, 1])
        }

        private func configureAutomaticLanguageDetection(
            fixture: BatchAudioTestFixture,
            candidates: BatchLanguageDetectionCandidateSnapshot = .init(
                scope: .selected,
                languageIdentifiers: ["en", "ja"],
                localeIdentifiers: ["en_US", "ja_JP"]
            )
        ) async throws {
            try await fixture.database.dbQueue.write { db in
                guard var session = try RecordingSessionRecord.fetchOne(db, key: fixture.session.id) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                session.batchLanguageDetectionMode = .automatic
                session.batchSelectedLocaleIdentifier = nil
                session.batchAutomaticLanguageCandidatesJSON = try candidates.encoded()
                try session.update(db)
            }
        }

        private func makeRecorder(
            fixture: BatchAudioTestFixture,
            targetSegmentDuration: Duration
        ) throws -> BatchAudioRecordingSession {
            try BatchAudioRecordingSession(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                meetingId: fixture.meeting.id,
                recordingSessionId: fixture.session.id,
                recordingStartTime: fixture.now,
                sampleRate: 16000,
                configuration: RecordingAudioStore.Configuration(
                    targetSegmentDuration: targetSegmentDuration,
                    maximumFinalizingSegmentCountPerSource: 2,
                    maximumActiveSegmentDuration: .seconds(600),
                    maximumActiveSegmentByteCount: 64 * 1024 * 1024,
                    minimumAvailableCapacity: 0,
                    capacityCheckInterval: .seconds(5)
                )
            )
        }

        private func makeBuffer(
            format: AVAudioFormat,
            frameCount: AVAudioFrameCount
        ) throws -> AVAudioPCMBuffer {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            return buffer
        }

        private func expectCompleteProgress(
            _ progressUpdates: [BatchTranscriptionProgress],
            totalFileCount: Int
        ) {
            #expect(progressUpdates.first == BatchTranscriptionProgress(
                completedFileCount: 0,
                totalFileCount: totalFileCount
            ))
            #expect(progressUpdates.last == BatchTranscriptionProgress(
                completedFileCount: totalFileCount,
                totalFileCount: totalFileCount
            ))
            #expect(progressUpdates.allSatisfy { $0.totalFileCount == totalFileCount })
            let completedFileCounts = progressUpdates.map(\.completedFileCount)
            #expect(completedFileCounts == completedFileCounts.sorted())
        }

        private func waitUntil(
            timeout: Duration = .seconds(5),
            condition: @escaping @Sendable () async -> Bool
        ) async throws {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while await !condition() {
                guard ContinuousClock.now < deadline else {
                    throw BatchTranscriptionProgressTestError.timedOut
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    extension BatchTranscriptionProgressTests {
        @Test
        func manualModeRecognizesContiguousCAFAsOneLogicalRun() async throws {
            let fixture = try makeFixture(name: "BatchManualLogicalRun", duration: 0.0125)
            defer { fixture.removeFiles() }
            try await createManualRecording(fixture: fixture, frameCounts: [80, 120])
            let stateProbe = BatchProgressStateProbe()
            let recognizer = ProgressSpeechRecognizer(pauseAfterFirstSlice: true)
            defer { Task { await recognizer.releaseFirstSlice() } }
            let coordinator = makeCoordinator(
                fixture: fixture,
                detector: ProgressLanguageDetector(detections: []),
                recognizer: recognizer,
                stateProbe: stateProbe
            )

            await coordinator.enqueue(sessionId: fixture.session.id)
            try await waitUntil { await recognizer.didConsumeFirstSlice }
            try await waitUntil {
                await stateProbe.reportedProgress().last?.completedFileCount == 1
            }
            #expect(!(await stateProbe.didComplete))
            await recognizer.releaseFirstSlice()
            try await waitUntil { await stateProbe.didComplete }

            #expect(await recognizer.fileCallCount == 0)
            #expect(await recognizer.sliceCounts == [2])
            expectCompleteProgress(await stateProbe.reportedProgress(), totalFileCount: 2)
            let transcript = try await fixture.database.dbQueue.read { db in
                try TranscriptSegmentRecord
                    .filter(Column("sessionId") == fixture.session.id)
                    .fetchOne(db)
            }
            #expect(transcript?.startTime == fixture.now.addingTimeInterval(0.001))
            #expect(transcript?.speakerLabel == RecordingAudioSource.microphone.speakerLabel)
        }
    }

    private enum BatchTranscriptionProgressTestError: Error {
        case timedOut
    }

    private actor BatchProgressStateProbe {
        private var states: [BatchTranscriptionState] = []

        var didComplete: Bool {
            states.contains {
                if case .completed = $0 {
                    true
                } else {
                    false
                }
            }
        }

        func record(_ state: BatchTranscriptionState) {
            states.append(state)
        }

        func reportedProgress() -> [BatchTranscriptionProgress] {
            states.compactMap { state in
                guard case let .running(_, progress?) = state else { return nil }
                return progress
            }
        }
    }

    private actor SuspendingBatchProgressStateProbe {
        private var progressContinuation: CheckedContinuation<Void, Never>?
        private(set) var isHoldingProgressCallback = false
        private(set) var didComplete = false
        private var hasHeldProgressCallback = false
        private var progressUpdates: [BatchTranscriptionProgress] = []

        func record(_ state: BatchTranscriptionState) async {
            if case .completed = state {
                didComplete = true
            }
            guard case let .running(_, progress?) = state else { return }
            progressUpdates.append(progress)
            guard progress.completedFileCount > 0,
                  !hasHeldProgressCallback else { return }
            hasHeldProgressCallback = true
            isHoldingProgressCallback = true
            await withCheckedContinuation { continuation in
                progressContinuation = continuation
            }
            isHoldingProgressCallback = false
        }

        func releaseProgressCallback() {
            progressContinuation?.resume()
            progressContinuation = nil
        }

        func reportedProgress() -> [BatchTranscriptionProgress] {
            progressUpdates
        }
    }

    private actor ProgressLanguageDetector: BatchLanguageDetecting {
        private var detections: [String]

        init(detections: [String]) {
            self.detections = detections
        }

        func detectLanguage(
            audioURL _: URL,
            allowedLanguageIdentifiers _: Set<String>?
        ) throws -> BatchLanguageDetectionOutcome {
            guard !detections.isEmpty else { throw BatchLanguageDetectorError.inferenceFailed }
            return .confidentDetection(detections.removeFirst())
        }

        func unload() async {}
    }

    private actor ProgressSpeechRecognizer: BatchSpeechRecognizing {
        private let pauseAfterFirstSlice: Bool
        private var firstSliceContinuation: CheckedContinuation<Void, Never>?
        private(set) var fileCallCount = 0
        private(set) var sliceCounts: [Int] = []
        private(set) var didConsumeFirstSlice = false

        init(pauseAfterFirstSlice: Bool = false) {
            self.pauseAfterFirstSlice = pauseAfterFirstSlice
        }

        var callCount: Int {
            fileCallCount + sliceCounts.count
        }

        func recognize(audioURL _: URL, locale _: Locale) -> [BatchSpeechRecognition] {
            fileCallCount += 1
            return [
                BatchSpeechRecognition(
                    startSeconds: 0.001,
                    endSeconds: 0.002,
                    text: "recognized-\(callCount)"
                ),
            ]
        }

        func recognize(
            audioSlices: [BatchSpeechAudioSlice],
            locale _: Locale
        ) -> [BatchSpeechRecognition] {
            sliceCounts.append(audioSlices.count)
            return [
                BatchSpeechRecognition(
                    startSeconds: 0.001,
                    endSeconds: 0.002,
                    text: "recognized-\(callCount)"
                ),
            ]
        }

        func recognize(
            audioSlices: [BatchSpeechAudioSlice],
            locale _: Locale,
            onSliceConsumed: @escaping @Sendable (Int) async -> Void
        ) async -> [BatchSpeechRecognition] {
            sliceCounts.append(audioSlices.count)
            for sliceIndex in audioSlices.indices {
                await onSliceConsumed(sliceIndex)
                if sliceIndex == audioSlices.startIndex, pauseAfterFirstSlice {
                    didConsumeFirstSlice = true
                    await withCheckedContinuation { continuation in
                        firstSliceContinuation = continuation
                    }
                }
            }
            return [
                BatchSpeechRecognition(
                    startSeconds: 0.001,
                    endSeconds: 0.002,
                    text: "recognized-\(callCount)"
                ),
            ]
        }

        func releaseFirstSlice() {
            firstSliceContinuation?.resume()
            firstSliceContinuation = nil
        }
    }
#endif
