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
        func separateProcessCannotAcquireProcessWideLock() async throws {
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
            #expect(await pollUntil { !child.isRunning })
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
            try writer.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 160))
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
            #expect(await pollUntil { !child.isRunning })
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
                maximumActiveSegmentByteCount: 64 * 1024 * 1024,
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
            let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if descriptor >= 0 { close(descriptor) }
                throw CocoaError(.fileLocking)
            }

            // `flock` follows the open file description across exec. Passing the descriptor as
            // stderr transfers the lock to a tiny native child without compiling or interpreting
            // a helper program on the test runner; closing stdin then ends the child naturally.
            let lockHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            let inputPipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/cat")
            process.standardInput = inputPipe
            process.standardError = lockHandle
            do {
                try process.run()
            } catch {
                inputPipe.fileHandleForWriting.closeFile()
                lockHandle.closeFile()
                throw error
            }
            lockHandle.closeFile()
            guard process.isRunning else { throw CocoaError(.fileLocking) }
            self.process = process
            standardInput = inputPipe.fileHandleForWriting
        }

        func release() {
            guard let standardInput else { return }
            standardInput.closeFile()
            self.standardInput = nil
        }

        var isRunning: Bool { process.isRunning }

        deinit {
            release()
        }
    }
#endif
