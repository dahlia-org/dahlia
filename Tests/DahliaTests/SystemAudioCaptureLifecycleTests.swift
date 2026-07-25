#if canImport(Testing)
    import Foundation
    import os
    import Testing
    @testable import Dahlia

    struct SystemAudioCaptureLifecycleTests {
        @Test
        func requestedStopSuppressesUnexpectedStopNotification() throws {
            var lifecycle = SystemAudioCaptureLifecycle()
            let startedGeneration = lifecycle.beginStart()
            let generation = try #require(startedGeneration)

            #expect(lifecycle.canContinueStart(generation: generation))
            #expect(lifecycle.requestStop() == .begin(generation: generation))
            #expect(!lifecycle.canContinueStart(generation: generation))
            #expect(lifecycle.beginDelegateCompletion(generation: generation) == nil)
            lifecycle.finishCompletion(generation: generation)
            #expect(lifecycle.activeGeneration == nil)
        }

        @Test
        func unexpectedStopIsReportedForTheActiveGeneration() throws {
            var lifecycle = SystemAudioCaptureLifecycle()
            let startedGeneration = lifecycle.beginStart()
            let generation = try #require(startedGeneration)

            #expect(lifecycle.beginDelegateCompletion(generation: generation) == true)
            lifecycle.finishCompletion(generation: generation)
            #expect(lifecycle.activeGeneration == nil)
        }

        @Test
        func staleCallbackCannotClearAReplacementCapture() throws {
            var lifecycle = SystemAudioCaptureLifecycle()
            let startedRetiredGeneration = lifecycle.beginStart()
            let retiredGeneration = try #require(startedRetiredGeneration)
            _ = lifecycle.requestStop()
            lifecycle.finishCompletion(generation: retiredGeneration)
            let startedActiveGeneration = lifecycle.beginStart()
            let activeGeneration = try #require(startedActiveGeneration)

            #expect(lifecycle.beginDelegateCompletion(generation: retiredGeneration) == nil)
            #expect(lifecycle.activeGeneration == activeGeneration)
            #expect(lifecycle.canContinueStart(generation: activeGeneration))
        }

        @Test
        func stopDuringPreparationInvalidatesThePendingStart() throws {
            var lifecycle = SystemAudioCaptureLifecycle()
            let startedGeneration = lifecycle.beginStart()
            let generation = try #require(startedGeneration)

            #expect(lifecycle.requestStop() == .begin(generation: generation))
            #expect(!lifecycle.canContinueStart(generation: generation))
            #expect(lifecycle.beginStart() == nil)
            lifecycle.finishCompletion(generation: generation)
            #expect(lifecycle.beginStart() != nil)
        }

        @Test
        func repeatedStopWaitsForTheExistingCompletionOwner() throws {
            var lifecycle = SystemAudioCaptureLifecycle()
            let startedGeneration = lifecycle.beginStart()
            let generation = try #require(startedGeneration)

            #expect(lifecycle.requestStop() == .begin(generation: generation))
            #expect(lifecycle.requestStop() == .wait(generation: generation))
            #expect(lifecycle.isCompletionInProgress)
            lifecycle.finishCompletion(generation: generation)
            #expect(lifecycle.requestStop() == nil)
        }

        @Test
        func callbackQueueDrainWaitsForEarlierWork() async {
            let callbackQueue = SystemAudioCallbackQueue(
                label: "com.dahlia.tests.systemaudio"
            )
            let gate = SystemAudioCallbackGate()
            callbackQueue.sampleHandlerQueue.async {
                gate.block()
            }
            #expect(await gate.waitUntilStarted())

            let drainState = OSAllocatedUnfairLock(initialState: false)
            let drainTask = Task {
                await callbackQueue.drain {
                    drainState.withLock { $0 = true }
                }
            }
            for _ in 0 ..< 100 {
                await Task.yield()
            }
            let completedBeforeRelease = drainState.withLock(\.self)
            #expect(!completedBeforeRelease)

            gate.release()
            await drainTask.value
            let completedAfterRelease = drainState.withLock(\.self)
            #expect(completedAfterRelease)
        }

        @Test
        func admittedSampleFinishesAfterAdmissionCloses() async {
            let callbackQueue = SystemAudioCallbackQueue(
                label: "com.dahlia.tests.systemaudio.admission"
            )
            let admission = SystemAudioSampleAdmission()
            let gate = SystemAudioCallbackGate()
            let deliveryState = OSAllocatedUnfairLock(initialState: false)
            callbackQueue.sampleHandlerQueue.async {
                admission.performIfAccepting {
                    gate.block()
                    deliveryState.withLock { $0 = true }
                }
            }
            #expect(await gate.waitUntilStarted())

            admission.deactivate()
            gate.release()
            await callbackQueue.drain {}

            let delivered = deliveryState.withLock(\.self)
            #expect(delivered)
            var acceptedAfterDeactivation = false
            admission.performIfAccepting {
                acceptedAfterDeactivation = true
            }
            #expect(!acceptedAfterDeactivation)
        }
    }

    private final class SystemAudioCallbackGate: @unchecked Sendable {
        private let hasStarted = OSAllocatedUnfairLock(initialState: false)
        private let releaseSemaphore = DispatchSemaphore(value: 0)

        func block() {
            hasStarted.withLock { $0 = true }
            _ = releaseSemaphore.wait(timeout: .now() + 10)
        }

        func release() {
            releaseSemaphore.signal()
        }

        func waitUntilStarted() async -> Bool {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                if hasStarted.withLock(\.self) {
                    return true
                }
                await Task.yield()
            }
            return false
        }
    }
#endif
