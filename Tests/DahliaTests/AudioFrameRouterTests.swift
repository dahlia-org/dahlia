@preconcurrency import AVFoundation
import Dispatch
import os
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct AudioFrameRouterTests {
        @Test
        func routesOneCapturedBufferToBatchAndLiveConsumers() async throws {
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 48000,
                channels: 1,
                interleaved: false
            ))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
            buffer.frameLength = 32
            let batchCount = OSAllocatedUnfairLock(initialState: 0)
            let liveCount = OSAllocatedUnfairLock(initialState: 0)
            let router = AudioFrameRouter()
            let pipeline = AudioSourcePipeline(
                source: .microphone,
                router: router,
                captureFormat: format,
                sessionRelativeOrigin: CMTime(seconds: 2, preferredTimescale: 48000)
            )
            router.setBatchConsumer { chunk in
                #expect(chunk.buffer === buffer)
                #expect(chunk.source == .microphone)
                #expect(chunk.sessionRelativeStartTime.seconds == 2)
                batchCount.withLock { $0 += 1 }
            }
            router.setLiveConsumer { chunk in
                #expect(chunk.buffer === buffer)
                liveCount.withLock { $0 += 1 }
                return true
            }

            router.route(pipeline.capture(buffer))
            router.removeAllConsumers()
            await router.waitUntilIdle()

            #expect(batchCount.withLock { $0 } == 1)
            #expect(liveCount.withLock { $0 } == 1)
        }

        @Test
        func detachingLiveConsumerDoesNotStopBatchConsumer() async throws {
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 48000,
                channels: 1,
                interleaved: false
            ))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
            buffer.frameLength = 1
            let batchCount = OSAllocatedUnfairLock(initialState: 0)
            let liveCount = OSAllocatedUnfairLock(initialState: 0)
            let router = AudioFrameRouter()
            let pipeline = AudioSourcePipeline(source: .microphone, router: router, captureFormat: format)
            router.setBatchConsumer { _ in batchCount.withLock { $0 += 1 } }
            router.setLiveConsumer { _ in
                liveCount.withLock { $0 += 1 }
                return true
            }
            router.setLiveConsumer(nil)

            router.route(pipeline.capture(buffer))
            await router.waitUntilIdle()

            #expect(batchCount.withLock { $0 } == 1)
            #expect(liveCount.withLock { $0 } == 0)
        }

        @Test
        func liveFailureDetachesConsumerAndReportsOnlyOnce() async throws {
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 48000,
                channels: 1,
                interleaved: false
            ))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
            buffer.frameLength = 1
            let liveCount = OSAllocatedUnfairLock(initialState: 0)
            let failureCount = OSAllocatedUnfairLock(initialState: 0)
            let failureSignal = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            let router = AudioFrameRouter()
            let pipeline = AudioSourcePipeline(source: .system, router: router, captureFormat: format)
            router.setLiveConsumer { _ in
                liveCount.withLock { $0 += 1 }
                return false
            } onFailure: {
                failureCount.withLock { $0 += 1 }
                failureSignal.continuation.yield()
            }

            router.route(pipeline.capture(buffer))
            router.route(pipeline.capture(buffer))
            var failureIterator = failureSignal.stream.makeAsyncIterator()
            _ = await failureIterator.next()
            await router.waitUntilIdle()

            #expect(liveCount.withLock { $0 } == 1)
            #expect(failureCount.withLock { $0 } == 1)
        }

        @Test
        func waitUntilIdleJoinsInFlightBatchCallback() async throws {
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 48000,
                channels: 1,
                interleaved: false
            ))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
            buffer.frameLength = 1
            let enteredConsumer = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            let releaseConsumer = DispatchSemaphore(value: 0)
            let didFinishWaiting = OSAllocatedUnfairLock(initialState: false)
            let router = AudioFrameRouter()
            let pipeline = AudioSourcePipeline(source: .microphone, router: router, captureFormat: format)
            router.setBatchConsumer { _ in
                enteredConsumer.continuation.yield()
                releaseConsumer.wait()
            }

            DispatchQueue.global(qos: .userInitiated).async {
                router.route(pipeline.capture(buffer))
            }
            var enteredIterator = enteredConsumer.stream.makeAsyncIterator()
            _ = await enteredIterator.next()
            router.removeAllConsumers()
            let waitTask = Task {
                await router.waitUntilIdle()
                didFinishWaiting.withLock { $0 = true }
            }
            try await Task.sleep(for: .milliseconds(20))
            #expect(!didFinishWaiting.withLock { $0 })

            releaseConsumer.signal()
            await waitTask.value
            #expect(didFinishWaiting.withLock { $0 })
        }

        @Test
        func sourcePipelineKeepsSessionClockAcrossChunks() throws {
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            let firstBuffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
            firstBuffer.frameLength = 160
            let secondBuffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80))
            secondBuffer.frameLength = 80
            let pipeline = AudioSourcePipeline(
                source: .system,
                captureFormat: format,
                sessionRelativeOrigin: CMTime(seconds: 3, preferredTimescale: 16000)
            )

            let first = pipeline.capture(firstBuffer)
            let second = pipeline.capture(secondBuffer)

            #expect(first.sessionRelativeStartSeconds == 3)
            #expect(second.sessionRelativeStartSeconds == 3.01)
        }

        @Test
        func sourcePipelineOriginCanBeFinalizedBeforeFirstCapture() throws {
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
            buffer.frameLength = 160
            let pipeline = AudioSourcePipeline(source: .microphone, captureFormat: format)

            pipeline.setSessionRelativeOrigin(seconds: 12.5)
            let chunk = pipeline.capture(buffer)
            pipeline.setSessionRelativeOrigin(seconds: 99)

            #expect(chunk.sessionRelativeStartSeconds == 12.5)
            #expect(pipeline.sessionRelativeOriginSeconds == 12.5)
        }
    }
#endif
