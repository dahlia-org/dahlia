#if canImport(Testing)
    @preconcurrency import AVFoundation
    import CoreMedia
    import Testing
    @testable import Dahlia

    struct AudioLevelMeteringWorkerTests {
        @Test
        func reportsSourceLevelAndCoalescesRapidFrames() async throws {
            let events = AsyncStream.makeStream(
                of: (RecordingAudioSource, Double).self,
                bufferingPolicy: .unbounded
            )
            let worker = AudioLevelMeteringWorker(source: .microphone) { source, level in
                events.continuation.yield((source, level))
            }
            var iterator = events.stream.makeAsyncIterator()

            try worker.enqueue(makeChunk(sample: 0.1, time: 0))
            let first = try #require(await iterator.next())
            #expect(first.0 == .microphone)
            #expect(first.1 > 0)

            try worker.enqueue(makeChunk(sample: 0.2, time: 0.02))
            try worker.enqueue(makeChunk(sample: 0.4, time: 0.1))
            let second = try #require(await iterator.next())
            #expect(second.1 > first.1)

            worker.cancel()
            await worker.waitUntilFinished()
            events.continuation.finish()
        }

        @Test
        func silenceReportsZero() async throws {
            let events = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
            let worker = AudioLevelMeteringWorker(source: .system) { _, level in
                events.continuation.yield(level)
            }
            var iterator = events.stream.makeAsyncIterator()

            try worker.enqueue(makeChunk(sample: 0, time: 0))

            #expect(try #require(await iterator.next()) == 0)
            worker.cancel()
            await worker.waitUntilFinished()
            events.continuation.finish()
        }

        @Test
        func slowHandlerRetainsOnlyLatestPendingFrame() async throws {
            let events = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .unbounded)
            let gate = MeteringHandlerGate()
            let worker = AudioLevelMeteringWorker(source: .microphone) { _, level in
                events.continuation.yield(level)
                await gate.waitIfBlocked()
            }
            var iterator = events.stream.makeAsyncIterator()

            try worker.enqueue(makeChunk(sample: 0.1, time: 0))
            _ = try #require(await iterator.next())
            try worker.enqueue(makeChunk(sample: 0.2, time: 0.1))
            try worker.enqueue(makeChunk(sample: 0.3, time: 0.2))
            try worker.enqueue(makeChunk(sample: 0.4, time: 0.3))
            await gate.release()

            let latestLevel = try #require(await iterator.next())
            #expect(try latestLevel == AudioLevelCalculator.normalizedLevel(
                in: makeChunk(sample: 0.4, time: 0).buffer
            ))
            worker.cancel()
            await worker.waitUntilFinished()
            events.continuation.finish()
        }

        private func makeChunk(sample: Float, time: TimeInterval) throws -> CapturedAudioChunk {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            buffer.frameLength = 128
            let samples = try #require(buffer.floatChannelData?[0])
            for frame in 0 ..< Int(buffer.frameLength) {
                samples[frame] = sample
            }
            return CapturedAudioChunk(
                source: .microphone,
                buffer: buffer,
                sessionRelativeStartTime: CMTime(seconds: time, preferredTimescale: 48000)
            )
        }
    }

    private actor MeteringHandlerGate {
        private var isBlocked = true
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func waitIfBlocked() async {
            guard isBlocked else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func release() {
            isBlocked = false
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }
#endif
