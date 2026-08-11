@preconcurrency import AVFoundation
import Darwin
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @Suite(.serialized)
    struct AdvisoryFileLockTests {
        @Test
        func separateProcessCannotAcquireProcessWideLock() throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-process-lock-\(UUID.v7().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let lockURL = rootURL.appending(path: ".process.lock")
            do {
                _ = try AdvisoryFileLock.acquire(at: lockURL)
            }

            let child = try ChildFlockProcess(lockURL: lockURL)
            defer { child.release() }
            do {
                _ = try AdvisoryFileLock.acquire(at: lockURL)
                Issue.record("The parent unexpectedly acquired a lock held by another process")
            } catch AdvisoryFileLockError.alreadyLocked {
                // Expected: the losing process must not proceed to open the database.
            }
            child.release()
            _ = try AdvisoryFileLock.acquire(at: lockURL)
        }

        @Test @MainActor
        func reconcilerSkipsSessionWhoseLeaseIsHeldBySeparateProcess() async throws {
            let fixture = try BatchAudioTestFixture(name: "ProcessSessionLease")
            defer { fixture.removeFiles() }
            let recorder = try BatchAudioRecordingSession(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                meetingId: fixture.meeting.id,
                recordingSessionId: fixture.session.id,
                recordingStartTime: fixture.now,
                sampleRate: 16000,
                configuration: testConfiguration
            )
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            writer.appendBuffer(try makeBuffer(format: recorder.targetFormat, frameCount: 160))
            try await recorder.finish()
            let ready = try await fixture.database.dbQueue.read { db in
                try #require(try RecordingAudioSegmentRecord.fetchOne(db))
            }
            let finalURL = fixture.managedRootURL.appending(path: ready.finalRelativePath)
            let partialURL = fixture.managedRootURL.appending(path: ready.partialRelativePath)
            try FileManager.default.moveItem(at: finalURL, to: partialURL)
            try await fixture.database.dbQueue.write { db in
                guard var record = try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id) else { return }
                record.state = .recording
                record.sealedFrameCount = nil
                record.byteCount = nil
                record.sha256 = nil
                record.integrityVerifiedAt = nil
                record.finalizedAt = nil
                try record.update(db)
            }

            let leaseURL = partialURL.deletingLastPathComponent().appending(path: ".lease")
            let child = try ChildFlockProcess(lockURL: leaseURL)
            let store = try RecordingAudioStore(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                configuration: testConfiguration
            )
            let skipped = await store.reconcileStartup()
            let unchanged = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id)
            }
            #expect(skipped.skippedActiveSessionCount == 1)
            #expect(unchanged?.state == .recording)
            #expect(FileManager.default.fileExists(atPath: partialURL.path))

            child.release()
            let recovered = await store.reconcileStartup()
            let current = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id)
            }
            #expect(recovered.recoveredSegmentCount == 1)
            #expect(current?.state == .ready)
            #expect(FileManager.default.fileExists(atPath: finalURL.path))
        }

        @MainActor
        private var testConfiguration: RecordingAudioStore.Configuration {
            RecordingAudioStore.Configuration(
                targetSegmentDuration: .seconds(60),
                maximumFinalizingSegmentCountPerSource: 2,
                maximumActiveSegmentDuration: .seconds(600),
                maximumActiveSegmentByteCount: 64 * 1_024 * 1_024,
                minimumAvailableCapacity: 0,
                capacityCheckInterval: .seconds(5)
            )
        }

        @MainActor
        private func makeBuffer(
            format: AVAudioFormat,
            frameCount: AVAudioFrameCount
        ) throws -> AVAudioPCMBuffer {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            return buffer
        }
    }

    private final class ChildFlockProcess {
        private let process: Process
        private var standardInput: FileHandle?

        init(lockURL: URL) throws {
            let helper = """
            import Darwin
            import Foundation
            let path = ProcessInfo.processInfo.environment["DAHLIA_TEST_LOCK_PATH"]!
            let descriptor = open(path, O_RDWR | O_CLOEXEC)
            guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { exit(2) }
            try! FileHandle.standardOutput.write(contentsOf: Data([1]))
            _ = try! FileHandle.standardInput.readToEnd()
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            """
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["swift", "-e", helper]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = Pipe()
            var environment = ProcessInfo.processInfo.environment
            environment["DAHLIA_TEST_LOCK_PATH"] = lockURL.path
            process.environment = environment
            try process.run()
            let status = try outputPipe.fileHandleForReading.read(upToCount: 1)
            guard status == Data([1]), process.isRunning else {
                inputPipe.fileHandleForWriting.closeFile()
                process.waitUntilExit()
                throw CocoaError(.fileLocking)
            }
            self.process = process
            standardInput = inputPipe.fileHandleForWriting
        }

        func release() {
            guard let standardInput else { return }
            standardInput.closeFile()
            self.standardInput = nil
            process.waitUntilExit()
        }

        deinit {
            release()
        }
    }
#endif
