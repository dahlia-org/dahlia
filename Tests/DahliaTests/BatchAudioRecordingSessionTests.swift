@preconcurrency import AVFoundation
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BatchAudioRecordingSessionTests {
        @Test
        func localeChangesCreateRangesInOneCAF() async throws {
            let fixture = try BatchAudioTestFixture(name: "Batch")
            defer { fixture.removeFiles() }

            let recorder = try BatchAudioRecordingSession(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                meetingId: fixture.meeting.id,
                recordingSessionId: fixture.session.id,
                recordingStartTime: fixture.now,
                sampleRate: 16000
            )
            let firstWriter = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            try firstWriter.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 160))
            try await recorder.endActiveRanges()

            let secondWriter = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "en_US"),
                at: fixture.now.addingTimeInterval(1)
            )
            #expect(firstWriter === secondWriter)
            try secondWriter.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 160))
            try await recorder.finish()

            let result = try await fixture.database.dbQueue.read { db in
                let files = try RecordingAudioFileRecord
                    .filter(Column("recordingSessionId") == fixture.session.id)
                    .fetchAll(db)
                let ranges = try RecordingAudioRangeRecord.order(Column("startFrame").asc).fetchAll(db)
                return (files, ranges)
            }
            let file = try #require(result.0.first)
            #expect(result.0.count == 1)
            #expect(file.storageLocation == .managed)
            #expect(file.totalFrameCount == 320)
            #expect(result.1.count == 2)
            #expect(result.1.map(\.localeIdentifier) == ["ja_JP", "en_US"])
            #expect(result.1.map(\.startFrame) == [0, 160])
            #expect(result.1.map(\.frameCount) == [160, 160])

            let finalURL = BatchAudioStorage.finalURL(baseURL: fixture.managedRootURL, relativePath: file.relativePath)
            let partialURL = BatchAudioStorage.partialURL(baseURL: fixture.managedRootURL, relativePath: file.relativePath)
            #expect(FileManager.default.fileExists(atPath: finalURL.path))
            #expect(!FileManager.default.fileExists(atPath: partialURL.path))
            let vaultAudioURL = BatchAudioStorage.finalURL(
                baseURL: fixture.vaultURL,
                relativePath: BatchAudioStorage.vaultRelativePath(
                    meetingId: fixture.meeting.id,
                    sessionId: fixture.session.id,
                    source: .microphone
                )
            )
            #expect(!FileManager.default.fileExists(atPath: vaultAudioURL.path))
            let audioFile = try AVAudioFile(forReading: finalURL)
            #expect(audioFile.length == 320)
        }

        @Test
        func rotatingLocaleUsesOneExactFrameBoundaryWithoutStoppingWriter() async throws {
            let fixture = try BatchAudioTestFixture(name: "BatchRotate")
            defer { fixture.removeFiles() }

            let recorder = try BatchAudioRecordingSession(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                meetingId: fixture.meeting.id,
                recordingSessionId: fixture.session.id,
                recordingStartTime: fixture.now,
                sampleRate: 16000
            )
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            try writer.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 80))

            let rotatedWriter = try await recorder.rotateRange(
                source: .microphone,
                locale: Locale(identifier: "en_US"),
                at: fixture.now.addingTimeInterval(0.005)
            )
            #expect(rotatedWriter === writer)
            try writer.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 120))
            try await recorder.finish()

            let ranges = try await fixture.database.dbQueue.read { db in
                try RecordingAudioRangeRecord.order(Column("startFrame").asc).fetchAll(db)
            }
            #expect(ranges.map(\.startFrame) == [0, 80])
            #expect(ranges.map(\.frameCount) == [80, 120])
        }

        @Test
        func rotatingMultipleSourcesIsAtomicAndUsesEachSourceFrameBoundary() async throws {
            let fixture = try BatchAudioTestFixture(name: "BatchAtomicRotate")
            defer { fixture.removeFiles() }

            let recorder = try BatchAudioRecordingSession(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                meetingId: fixture.meeting.id,
                recordingSessionId: fixture.session.id,
                recordingStartTime: fixture.now,
                sampleRate: 16000
            )
            let microphoneWriter = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now.addingTimeInterval(0.25)
            )
            let systemWriter = try await recorder.beginRange(
                source: .system,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now.addingTimeInterval(0.5)
            )
            try microphoneWriter.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 80))
            try systemWriter.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 120))

            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER reject_second_english_range
                BEFORE INSERT ON recording_audio_ranges
                WHEN NEW.localeIdentifier = 'en_US'
                    AND (SELECT COUNT(*) FROM recording_audio_ranges WHERE localeIdentifier = 'en_US') >= 1
                BEGIN
                    SELECT RAISE(ABORT, 'forced range rotation failure');
                END
                """)
            }
            await #expect(throws: (any Error).self) {
                try await recorder.rotateRanges(
                    [
                        (source: .microphone, sessionRelativeOriginSeconds: 0.25),
                        (source: .system, sessionRelativeOriginSeconds: 0.5),
                    ],
                    locale: Locale(identifier: "en_US")
                )
            }

            let rangesAfterFailure = try await fixture.database.dbQueue.read { db in
                try RecordingAudioRangeRecord.fetchAll(db)
            }
            #expect(rangesAfterFailure.count == 2)
            #expect(rangesAfterFailure.allSatisfy { $0.localeIdentifier == "ja_JP" && $0.frameCount == nil })

            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "DROP TRIGGER reject_second_english_range")
            }
            try await recorder.rotateRanges(
                [
                    (source: .microphone, sessionRelativeOriginSeconds: 0.25),
                    (source: .system, sessionRelativeOriginSeconds: 0.5),
                ],
                locale: Locale(identifier: "en_US")
            )
            try microphoneWriter.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 40))
            try systemWriter.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 60))
            try await recorder.finish()

            let result = try await fixture.database.dbQueue.read { db in
                let files = try RecordingAudioFileRecord
                    .filter(Column("recordingSessionId") == fixture.session.id)
                    .fetchAll(db)
                let ranges = try RecordingAudioRangeRecord.order(Column("startFrame").asc).fetchAll(db)
                return (files, ranges)
            }
            let fileBySource = Dictionary(uniqueKeysWithValues: result.0.map { ($0.source, $0) })
            let microphoneFile = try #require(fileBySource[.microphone])
            let systemFile = try #require(fileBySource[.system])
            let microphoneRanges = result.1.filter { $0.audioFileId == microphoneFile.id }
            let systemRanges = result.1.filter { $0.audioFileId == systemFile.id }

            #expect(microphoneRanges.map(\.startFrame) == [0, 80])
            #expect(microphoneRanges.map(\.frameCount) == [80, 40])
            #expect(abs((microphoneRanges.last?.sessionOffsetSeconds ?? 0) - 0.255) < 0.000_001)
            #expect(systemRanges.map(\.startFrame) == [0, 120])
            #expect(systemRanges.map(\.frameCount) == [120, 60])
            #expect(abs((systemRanges.last?.sessionOffsetSeconds ?? 0) - 0.5075) < 0.000_001)
        }

        @Test
        func sealingWriterRejectsLateCallbackWithoutChangingFrameMetadata() async throws {
            let fixture = try BatchAudioTestFixture(name: "BatchSeal")
            defer { fixture.removeFiles() }

            let recorder = try BatchAudioRecordingSession(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                meetingId: fixture.meeting.id,
                recordingSessionId: fixture.session.id,
                recordingStartTime: fixture.now,
                sampleRate: 16000
            )
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP")
            )
            try writer.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 100))
            #expect(writer.seal() == 100)
            try writer.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 50))
            try await recorder.finish()

            let result = try await fixture.database.dbQueue.read { db in
                let file = try RecordingAudioFileRecord
                    .filter(Column("recordingSessionId") == fixture.session.id)
                    .fetchOne(db)
                let range = try RecordingAudioRangeRecord.fetchOne(db)
                return (file, range)
            }
            #expect(result.0?.totalFrameCount == 100)
            #expect(result.1?.frameCount == 100)
        }

        @Test
        func writerQueueOverflowIsReportedAsRecordingFailure() async throws {
            let fixture = try BatchAudioTestFixture(name: "BatchWriterOverflow")
            defer { fixture.removeFiles() }
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            let partialURL = fixture.managedRootURL.appending(path: "overflow.partial.caf")
            let finalURL = fixture.managedRootURL.appending(path: "overflow.caf")
            let writer = BatchAudioFileWriter(
                partialURL: partialURL,
                finalURL: finalURL,
                format: format,
                maximumBufferedChunkCount: 1
            )

            try writer.appendBuffer(makeBuffer(format: format, frameCount: 16))
            try writer.appendBuffer(makeBuffer(format: format, frameCount: 16))
            try await writer.start()

            await #expect(throws: BatchAudioFileWriterError.self) {
                try await writer.finish()
            }
        }

        @Test
        func failedRangeCloseRemainsActiveAndMakesFinishFailAfterRetrySucceeds() async throws {
            let fixture = try BatchAudioTestFixture(name: "BatchRangeCloseFailure")
            defer { fixture.removeFiles() }

            let recorder = try BatchAudioRecordingSession(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                meetingId: fixture.meeting.id,
                recordingSessionId: fixture.session.id,
                recordingStartTime: fixture.now,
                sampleRate: 16000
            )
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            try writer.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 80))

            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER reject_range_close
                BEFORE UPDATE ON recording_audio_ranges
                WHEN NEW.frameCount IS NOT NULL
                BEGIN
                    SELECT RAISE(ABORT, 'forced range close failure');
                END
                """)
            }
            await #expect(throws: (any Error).self) {
                try await recorder.endRangeForReconfiguration(source: .microphone)
            }

            let rangeAfterFailure = try await fixture.database.dbQueue.read { db in
                try RecordingAudioRangeRecord.fetchOne(db)
            }
            #expect(rangeAfterFailure?.frameCount == nil)

            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "DROP TRIGGER reject_range_close")
            }
            try writer.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 40))
            try await recorder.endRangeForReconfiguration(source: .microphone)

            let rangeAfterRetry = try await fixture.database.dbQueue.read { db in
                try RecordingAudioRangeRecord.fetchOne(db)
            }
            #expect(rangeAfterRetry?.frameCount == 120)
            await #expect(throws: (any Error).self) {
                try await recorder.finish()
            }

            let result = try await fixture.database.dbQueue.read { db in
                let file = try RecordingAudioFileRecord
                    .filter(Column("recordingSessionId") == fixture.session.id)
                    .fetchOne(db)
                let range = try RecordingAudioRangeRecord.fetchOne(db)
                return (file, range)
            }
            #expect(result.0?.totalFrameCount == 120)
            #expect(result.1?.frameCount == 120)
        }

        private func makeBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            let channel = try #require(buffer.int16ChannelData?[0])
            for index in 0 ..< Int(frameCount) {
                channel[index] = Int16(index % 100)
            }
            return buffer
        }
    }
#endif
