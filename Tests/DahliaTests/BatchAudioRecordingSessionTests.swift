@preconcurrency import AVFoundation
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
    struct BatchAudioRecordingSessionTests {
        @Test
        func finalizesImmutableSegmentWithIntegrityMetadataAndLocaleRanges() async throws {
            let fixture = try BatchAudioTestFixture(name: "SegmentedBatch")
            defer { fixture.removeFiles() }
            let recorder = try makeRecorder(fixture: fixture)
            let firstWriter = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            firstWriter.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 160))
            let secondWriter = try await recorder.rotateRange(
                source: .microphone,
                locale: Locale(identifier: "en_US")
            )
            #expect(firstWriter === secondWriter)
            secondWriter.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 160))
            try await recorder.finish()

            let result = try await fixture.database.dbQueue.read { db in
                let segments = try RecordingAudioSegmentRecord.fetchAll(db)
                let ranges = try RecordingAudioSegmentRangeRecord.order(Column("startFrame").asc).fetchAll(db)
                let progress = try RecordingAudioSourceProgressRecord.fetchAll(db)
                return (segments, ranges, progress)
            }
            let segment = try #require(result.0.first)
            #expect(result.0.count == 1)
            #expect(segment.state == .ready)
            #expect(segment.sealedFrameCount == 320)
            #expect(segment.byteCount.map { $0 > 0 } == true)
            #expect(segment.sha256?.count == 32)
            #expect(segment.integrityVerifiedAt != nil)
            #expect(segment.finalizedAt != nil)
            #expect(result.1.map(\.localeIdentifier) == ["ja_JP", "en_US"])
            #expect(result.1.map(\.startFrame) == [0, 160])
            #expect(result.1.map(\.frameCount) == [160, 160])
            #expect(result.2.first?.durableThroughOffsetSeconds == 0.02)
            #expect(result.2.first?.lastContiguousReadySegmentIndex == 0)

            let finalURL = fixture.managedRootURL.appending(path: segment.finalRelativePath)
            let partialURL = fixture.managedRootURL.appending(path: segment.partialRelativePath)
            #expect(FileManager.default.fileExists(atPath: finalURL.path))
            #expect(!FileManager.default.fileExists(atPath: partialURL.path))
            #expect(try AVAudioFile(forReading: finalURL).length == 320)
        }

        @Test
        func rotatesAtBufferBoundaryWithoutFrameLossOrDuplication() async throws {
            let fixture = try BatchAudioTestFixture(name: "SegmentRotation")
            defer { fixture.removeFiles() }
            let recorder = try makeRecorder(
                fixture: fixture,
                configuration: configuration(targetMilliseconds: 5)
            )
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            writer.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 80, startValue: 0))
            writer.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 120, startValue: 80))
            try await recorder.finish()

            let segments = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.order(Column("segmentIndex").asc).fetchAll(db)
            }
            #expect(segments.count == 2)
            #expect(segments.map(\.segmentIndex) == [0, 1])
            #expect(segments.map(\.sealedFrameCount) == [80, 120])
            #expect(segments.allSatisfy { $0.state == .ready && $0.sha256?.count == 32 })
            #expect(segments[0].sessionEndOffsetSeconds == segments[1].sessionStartOffsetSeconds)

            var samples: [Int16] = []
            for segment in segments {
                let url = fixture.managedRootURL.appending(path: segment.finalRelativePath)
                samples.append(contentsOf: try readSamples(url: url))
            }
            #expect(samples == (0 ..< 200).map { Int16($0) })
        }

        @Test
        func localeRotationAcrossSourcesIsAtomic() async throws {
            let fixture = try BatchAudioTestFixture(name: "AtomicLocale")
            defer { fixture.removeFiles() }
            let recorder = try makeRecorder(fixture: fixture)
            let microphone = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now.addingTimeInterval(0.25)
            )
            let system = try await recorder.beginRange(
                source: .system,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now.addingTimeInterval(0.5)
            )
            microphone.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 80))
            system.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 120))

            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER reject_second_segment_english_range
                BEFORE INSERT ON recording_audio_segment_ranges
                WHEN NEW.localeIdentifier = 'en_US'
                    AND (SELECT COUNT(*) FROM recording_audio_segment_ranges WHERE localeIdentifier = 'en_US') >= 1
                BEGIN
                    SELECT RAISE(ABORT, 'forced range rotation failure');
                END
                """)
            }
            await #expect(throws: (any Error).self) {
                try await recorder.rotateRanges(
                    [
                        BatchRecordingRangeOrigin(source: .microphone, startFrame: 0, sessionRelativeOriginSeconds: 0.25),
                        BatchRecordingRangeOrigin(source: .system, startFrame: 0, sessionRelativeOriginSeconds: 0.5),
                    ],
                    locale: Locale(identifier: "en_US")
                )
            }
            let rangesAfterFailure = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRangeRecord.fetchAll(db)
            }
            #expect(rangesAfterFailure.count == 2)
            #expect(rangesAfterFailure.allSatisfy { $0.localeIdentifier == "ja_JP" && $0.frameCount == nil })

            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "DROP TRIGGER reject_second_segment_english_range")
            }
            _ = try await recorder.rotateRanges(
                [
                    BatchRecordingRangeOrigin(source: .microphone, startFrame: 0, sessionRelativeOriginSeconds: 0.25),
                    BatchRecordingRangeOrigin(source: .system, startFrame: 0, sessionRelativeOriginSeconds: 0.5),
                ],
                locale: Locale(identifier: "en_US")
            )
            microphone.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 40))
            system.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 60))
            try await recorder.finish()

            let result = try await fixture.database.dbQueue.read { db in
                let segments = try RecordingAudioSegmentRecord.fetchAll(db)
                let ranges = try RecordingAudioSegmentRangeRecord.order(Column("startFrame").asc).fetchAll(db)
                return (segments, ranges)
            }
            let segmentBySource = Dictionary(uniqueKeysWithValues: result.0.map { ($0.source, $0) })
            let microphoneSegment = try #require(segmentBySource[.microphone])
            let systemSegment = try #require(segmentBySource[.system])
            #expect(result.1.filter { $0.audioSegmentId == microphoneSegment.id }.map(\.frameCount) == [80, 40])
            #expect(result.1.filter { $0.audioSegmentId == systemSegment.id }.map(\.frameCount) == [120, 60])
            let durable = await recorder.fullyDurableThroughOffsetSeconds()
            #expect(abs(durable - 0.2575) < 0.000_001)
        }

        @Test
        func sealingRejectsLateCallbackAndPreservesSealedFrameCount() async throws {
            let fixture = try BatchAudioTestFixture(name: "SegmentSeal")
            defer { fixture.removeFiles() }
            let recorder = try makeRecorder(fixture: fixture)
            let writer = try await recorder.beginRange(source: .microphone, locale: Locale(identifier: "ja_JP"))
            writer.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 100))
            #expect(writer.seal() == 100)
            writer.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 50))
            try await recorder.finish()

            let segment = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db)
            }
            #expect(segment?.state == .ready)
            #expect(segment?.sealedFrameCount == 100)
        }

        @Test
        func sourceReconfigurationUsesNewGenerationWithoutReplacingReadySegment() async throws {
            let fixture = try BatchAudioTestFixture(name: "SourceReconfiguration")
            defer { fixture.removeFiles() }
            let recorder = try makeRecorder(fixture: fixture)
            let first = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            first.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 80))
            try await recorder.endRangeForReconfiguration(source: .microphone)
            let second = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now.addingTimeInterval(1)
            )
            second.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 120))
            try await recorder.finish()

            let segments = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.order(Column("segmentIndex").asc).fetchAll(db)
            }
            #expect(segments.count == 2)
            #expect(segments.map(\.segmentIndex) == [0, 1])
            #expect(segments[0].generationId != segments[1].generationId)
            #expect(segments.map(\.sealedFrameCount) == [80, 120])
            #expect(segments.allSatisfy { $0.state == .ready })
            let progress = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSourceProgressRecord.fetchOne(db)
            }
            #expect(progress?.isRequired == true)
            #expect(progress?.durableThroughOffsetSeconds == 0.005)
        }

        @Test
        func boundedBacklogExtendsActiveSegmentThenResumesRotation() async throws {
            let fixture = try BatchAudioTestFixture(name: "FinalizationBacklog")
            defer { fixture.removeFiles() }
            let configuration = RecordingAudioStore.Configuration(
                targetSegmentDuration: .milliseconds(5),
                maximumFinalizingSegmentCountPerSource: 2,
                maximumActiveSegmentDuration: .seconds(600),
                maximumActiveSegmentByteCount: 64 * 1_024 * 1_024,
                minimumAvailableCapacity: 0,
                capacityCheckInterval: .seconds(5),
                simulatedFinalizationDelay: .milliseconds(250)
            )
            let recorder = try makeRecorder(fixture: fixture, configuration: configuration)
            let eventTask = Task { () -> [BatchRecordingEvent] in
                var events: [BatchRecordingEvent] = []
                for await event in recorder.events {
                    events.append(event)
                }
                return events
            }
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            for offset in 0 ..< 4 {
                writer.appendBuffer(try makeBuffer(
                    format: recorder.targetFormat,
                    frameCount: 80,
                    startValue: offset * 80
                ))
            }
            try await Task.sleep(for: .milliseconds(75))
            let delayed = await writer.backlogSnapshot()
            #expect(delayed.segmentCount == 2)
            #expect(delayed.pendingByteCount == 320)
            #expect(delayed.oldestFinalizationStartedAt != nil)

            try await Task.sleep(for: .milliseconds(600))
            let recovered = await writer.backlogSnapshot()
            #expect(recovered.segmentCount == 0)
            writer.appendBuffer(try makeBuffer(
                format: recorder.targetFormat,
                frameCount: 80,
                startValue: 320
            ))
            try await recorder.finish()
            let events = await eventTask.value

            #expect(events.contains { event in
                if case .finalizationDelayed(source: .microphone) = event { return true }
                return false
            })
            #expect(events.contains { event in
                if case .finalizationRecovered(source: .microphone) = event { return true }
                return false
            })
            let segments = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.order(Column("segmentIndex").asc).fetchAll(db)
            }
            #expect(segments.map(\.sealedFrameCount) == [80, 80, 160, 80])
            #expect(segments.allSatisfy { $0.state == .ready })
        }

        @Test
        func activeSafetyBudgetStopsAfterPreservingAcceptedFrames() async throws {
            let fixture = try BatchAudioTestFixture(name: "ActiveSafetyBudget")
            defer { fixture.removeFiles() }
            let configuration = RecordingAudioStore.Configuration(
                targetSegmentDuration: .seconds(60),
                maximumFinalizingSegmentCountPerSource: 2,
                maximumActiveSegmentDuration: .seconds(600),
                maximumActiveSegmentByteCount: 100,
                minimumAvailableCapacity: 0,
                capacityCheckInterval: .seconds(5)
            )
            let recorder = try makeRecorder(fixture: fixture, configuration: configuration)
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            writer.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 80))

            await #expect(throws: RecordingAudioStoreError.activeSegmentSafetyLimit) {
                try await recorder.finish()
            }
            let segment = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db)
            }
            #expect(segment?.state == .ready)
            #expect(segment?.sealedFrameCount == 80)
            #expect(segment?.sha256?.count == 32)
        }

        @Test
        func writeQueueOverflowRejectsLaterBuffersAndPreservesAcceptedPrefix() async throws {
            let fixture = try BatchAudioTestFixture(name: "WriteQueueOverflow")
            defer { fixture.removeFiles() }
            let recorder = try makeRecorder(fixture: fixture)
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            let buffer = try makeBuffer(format: recorder.targetFormat, frameCount: 1)
            for _ in 0 ..< 300 {
                writer.appendBuffer(buffer)
            }
            let acceptedPrefixFrameCount = writer.acceptedFrameCount
            #expect(acceptedPrefixFrameCount < 300)

            _ = await writer.captureLocaleBoundary()
            for _ in 0 ..< 10 {
                writer.appendBuffer(buffer)
            }
            #expect(writer.acceptedFrameCount == acceptedPrefixFrameCount)

            await #expect(throws: RecordingAudioStoreError.writeQueueOverflow) {
                try await recorder.finish()
            }
            let segment = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db)
            }
            #expect(segment?.state == .ready)
            #expect(segment?.sealedFrameCount == acceptedPrefixFrameCount)
        }

        @Test
        func durabilityUsesMinimumRequiredSourceAndExcludesLateSource() async throws {
            let fixture = try BatchAudioTestFixture(name: "RequiredSourceDurability")
            defer { fixture.removeFiles() }
            let recorder = try makeRecorder(fixture: fixture)
            let microphone = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            microphone.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 160))
            await recorder.freezeRequiredSources()
            let lateSystem = try await recorder.beginRange(
                source: .system,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            lateSystem.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 80))
            try await recorder.finish()

            let durable = await recorder.fullyDurableThroughOffsetSeconds()
            let progress = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSourceProgressRecord
                    .order(Column("source").asc)
                    .fetchAll(db)
            }
            #expect(durable == 0.01)
            #expect(progress.first(where: { $0.source == .microphone })?.isRequired == true)
            #expect(progress.first(where: { $0.source == .system })?.isRequired == false)
        }

        private func makeRecorder(
            fixture: BatchAudioTestFixture,
            configuration: RecordingAudioStore.Configuration = .production
        ) throws -> BatchAudioRecordingSession {
            try BatchAudioRecordingSession(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                meetingId: fixture.meeting.id,
                recordingSessionId: fixture.session.id,
                recordingStartTime: fixture.now,
                sampleRate: 16000,
                configuration: configuration
            )
        }

        private func configuration(targetMilliseconds: Int64) -> RecordingAudioStore.Configuration {
            RecordingAudioStore.Configuration(
                targetSegmentDuration: .milliseconds(targetMilliseconds),
                maximumFinalizingSegmentCountPerSource: 2,
                maximumActiveSegmentDuration: .seconds(600),
                maximumActiveSegmentByteCount: 64 * 1_024 * 1_024,
                minimumAvailableCapacity: 0,
                capacityCheckInterval: .seconds(5)
            )
        }

        private func makeBuffer(
            format: AVAudioFormat,
            frameCount: AVAudioFrameCount,
            startValue: Int = 0
        ) throws -> AVAudioPCMBuffer {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            let channel = try #require(buffer.int16ChannelData?[0])
            for index in 0 ..< Int(frameCount) {
                channel[index] = Int16(startValue + index)
            }
            return buffer
        }

        private func readSamples(url: URL) throws -> [Int16] {
            let file = try AVAudioFile(
                forReading: url,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
            let frameCount = AVAudioFrameCount(file.length)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount))
            try file.read(into: buffer)
            let channel = try #require(buffer.int16ChannelData?[0])
            return (0 ..< Int(buffer.frameLength)).map { channel[$0] }
        }
    }
#endif
