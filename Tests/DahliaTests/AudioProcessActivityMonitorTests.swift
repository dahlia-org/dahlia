import CoreAudio
import Foundation
import os
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct AudioProcessActivityMonitorTests {
        @Test
        func publishesInitialAndChangedValuesWithoutDuplicates() async {
            let inputReads = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .unbounded)
            let harness = AudioProcessActivityMonitorHarness(inputReadContinuation: inputReads.continuation)
            harness.configureProcess(bundleID: "us.zoom.caphost", isRunningInput: true)
            let monitor = AudioProcessActivityMonitor(dependencies: harness.dependencies, excludedPID: 999)
            let events = OSAllocatedUnfairLock(
                initialState: [AudioProcessActivityMonitor.RunningInputBundleIDsResult]()
            )

            let observerID = await monitor.addRunningInputObserver { result in
                events.withLock { $0.append(result) }
            }
            var inputReadIterator = inputReads.stream.makeAsyncIterator()
            _ = await inputReadIterator.next()

            harness.fireInputListener()
            _ = await inputReadIterator.next()
            _ = await monitor.isMonitoring()
            #expect(events.withLock { $0.count } == 1)

            harness.setRunningInput(false)
            harness.fireInputListener()
            _ = await inputReadIterator.next()
            _ = await monitor.isMonitoring()

            let values = events.withLock { $0 }
            #expect(values.count == 2)
            #expect((try? values[0].get()) == Set(["us.zoom.caphost"]))
            #expect((try? values[1].get()) == Set<String>())
            await monitor.removeRunningInputObserver(observerID)
        }

        @Test
        func refreshesCachedInputStateWhenCoreAudioDoesNotNotify() async {
            let harness = AudioProcessActivityMonitorHarness()
            harness.configureProcess(bundleID: "com.google.Chrome.helper", isRunningInput: false)
            let monitor = AudioProcessActivityMonitor(dependencies: harness.dependencies, excludedPID: 999)
            let events = OSAllocatedUnfairLock(
                initialState: [AudioProcessActivityMonitor.RunningInputBundleIDsResult]()
            )

            let observerID = await monitor.addRunningInputObserver { result in
                events.withLock { $0.append(result) }
            }
            harness.setRunningInput(true)
            await monitor.refreshRunningInputState()

            let values = events.withLock { $0 }
            #expect(values.count == 2)
            #expect((try? values[0].get()) == Set<String>())
            #expect((try? values[1].get()) == Set(["com.google.Chrome.helper"]))
            await monitor.removeRunningInputObserver(observerID)
        }

        @Test
        func keepsSharedListenersUntilDebugAndMeetingConsumersStop() async {
            let harness = AudioProcessActivityMonitorHarness()
            harness.configureProcess(bundleID: "com.microsoft.teams2.audio", isRunningInput: true)
            let monitor = AudioProcessActivityMonitor(dependencies: harness.dependencies, excludedPID: 999)

            let observerID = await monitor.addRunningInputObserver { _ in }
            #expect(harness.activeSelectors == [
                kAudioHardwarePropertyProcessObjectList,
                kAudioProcessPropertyIsRunningInput,
            ])

            await monitor.startMonitoring()
            #expect(harness.activeSelectors.contains(kAudioProcessPropertyIsRunningOutput))

            await monitor.stopMonitoring()
            #expect(harness.activeSelectors == [
                kAudioHardwarePropertyProcessObjectList,
                kAudioProcessPropertyIsRunningInput,
            ])

            await monitor.removeRunningInputObserver(observerID)
            #expect(harness.activeSelectors.isEmpty)
        }

        @Test
        func retriesListenerRegistrationAfterFailureWithoutPublishingEmptyState() async throws {
            let listenerAdds = AsyncStream.makeStream(
                of: AudioObjectPropertySelector.self,
                bufferingPolicy: .unbounded
            )
            let harness = AudioProcessActivityMonitorHarness(listenerAddContinuation: listenerAdds.continuation)
            harness.configureProcess(bundleID: "com.tinyspeck.slackmacgap.helper", isRunningInput: true)
            harness.failNextAdd(selector: kAudioHardwarePropertyProcessObjectList)
            let monitor = AudioProcessActivityMonitor(
                dependencies: harness.dependencies,
                excludedPID: 999,
                retryInterval: .zero
            )
            let events = OSAllocatedUnfairLock(
                initialState: [AudioProcessActivityMonitor.RunningInputBundleIDsResult]()
            )

            let observerID = await monitor.addRunningInputObserver { result in
                events.withLock { $0.append(result) }
            }
            var listenerAddIterator = listenerAdds.stream.makeAsyncIterator()
            _ = await listenerAddIterator.next()
            _ = await listenerAddIterator.next()
            #expect(await pollUntil { events.withLock { $0.count >= 2 } })

            let values = events.withLock { $0 }
            #expect(values.count == 2)
            let first = try #require(values.first)
            let second = try #require(values.dropFirst().first)
            if case let .failure(failure) = first {
                #expect(failure.operation == .addListener)
            } else {
                Issue.record("Expected an initial listener-registration failure")
            }
            #expect((try? second.get()) == Set(["com.tinyspeck.slackmacgap.helper"]))
            await monitor.removeRunningInputObserver(observerID)
        }
    }

    struct MeetingAudioActivityMonitorEventTests {
        @Test
        func pollsCachedInputStateWithoutReenumeratingProcesses() async {
            let harness = AudioProcessActivityMonitorHarness()
            harness.configureProcess(bundleID: "com.google.Chrome.helper", isRunningInput: false)
            let activityMonitor = AudioProcessActivityMonitor(dependencies: harness.dependencies, excludedPID: 999)
            let snapshots = AsyncStream.makeStream(
                of: MeetingAudioActivityMonitor.Snapshot.self,
                bufferingPolicy: .unbounded
            )
            let monitor = MeetingAudioActivityMonitor(
                pollInterval: .milliseconds(1),
                activityMonitor: activityMonitor
            )

            await monitor.start { snapshot in
                snapshots.continuation.yield(snapshot)
            }
            var snapshotIterator = snapshots.stream.makeAsyncIterator()
            let initial = await snapshotIterator.next()
            #expect(initial?.activeContexts.isEmpty == true)

            harness.setRunningInput(true)
            let started = await snapshotIterator.next()
            #expect(started?.startedContexts == [.chrome])
            #expect(harness.processListReadCount == 1)

            await monitor.stop()
        }

        @Test
        func evaluatesOnceAtDisappearanceDeadlineAndUnsubscribesOnStop() async {
            let harness = AudioProcessActivityMonitorHarness()
            harness.configureProcess(bundleID: "us.zoom.caphost", isRunningInput: true)
            let activityMonitor = AudioProcessActivityMonitor(dependencies: harness.dependencies, excludedPID: 999)
            let initialInstant = ContinuousClock.now
            let currentInstant = OSAllocatedUnfairLock(initialState: initialInstant)
            let snapshots = AsyncStream.makeStream(
                of: MeetingAudioActivityMonitor.Snapshot.self,
                bufferingPolicy: .unbounded
            )
            let monitor = MeetingAudioActivityMonitor(
                disappearanceGracePeriod: .seconds(4),
                activityMonitor: activityMonitor,
                now: { currentInstant.withLock { $0 } },
                sleepUntil: { deadline in
                    currentInstant.withLock { $0 = deadline }
                }
            )

            await monitor.start { snapshot in
                snapshots.continuation.yield(snapshot)
            }
            var snapshotIterator = snapshots.stream.makeAsyncIterator()
            let initial = await snapshotIterator.next()
            #expect(initial?.activeContexts == [.zoom])

            let disappearedAt = initialInstant.advanced(by: .seconds(30))
            currentInstant.withLock { $0 = disappearedAt }
            harness.setRunningInput(false)
            harness.fireInputListener()

            let disappeared = await snapshotIterator.next()
            let ended = await snapshotIterator.next()
            #expect(disappeared?.activeContexts == [.zoom])
            #expect(disappeared?.endedContexts.isEmpty == true)
            #expect(disappeared?.lastSeenAt[.zoom] == disappearedAt)
            #expect(ended?.activeContexts.isEmpty == true)
            #expect(ended?.endedContexts == [.zoom])
            #expect(ended?.lastSeenAt[.zoom] == disappearedAt)
            #expect(ended?.observedAt == disappearedAt.advanced(by: .seconds(4)))

            await monitor.stop()
            #expect(harness.activeSelectors.isEmpty)
        }
    }

    private final class AudioProcessActivityMonitorHarness: Sendable {
        private struct ListenerKey: Hashable {
            let objectID: AudioObjectID
            let selector: AudioObjectPropertySelector
        }

        /// CoreAudio listener blocks are only accessed while `state` is locked.
        private struct StoredListener: @unchecked Sendable {
            let value: AudioProcessActivityMonitor.PropertyListener
        }

        private struct State: Sendable {
            var objectIDs = [AudioObjectID]()
            var pids = [AudioObjectID: pid_t]()
            var bundleIDs = [AudioObjectID: String]()
            var runningInputs = [AudioObjectID: Bool]()
            var runningOutputs = [AudioObjectID: Bool]()
            var listeners = [ListenerKey: StoredListener]()
            var failedAddSelectors = Set<AudioObjectPropertySelector>()
            var processListReadCount = 0
        }

        private let processObjectID = AudioObjectID(42)
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let inputReadContinuation: AsyncStream<Void>.Continuation?
        private let listenerAddContinuation: AsyncStream<AudioObjectPropertySelector>.Continuation?

        init(
            inputReadContinuation: AsyncStream<Void>.Continuation? = nil,
            listenerAddContinuation: AsyncStream<AudioObjectPropertySelector>.Continuation? = nil
        ) {
            self.inputReadContinuation = inputReadContinuation
            self.listenerAddContinuation = listenerAddContinuation
        }

        var dependencies: AudioProcessActivityMonitor.Dependencies {
            AudioProcessActivityMonitor.Dependencies(
                processObjectIDs: { [self] in
                    state.withLock { state in
                        state.processListReadCount += 1
                        return .success(state.objectIDs)
                    }
                },
                pid: { [self] objectID in
                    state.withLock { .success($0.pids[objectID] ?? 0) }
                },
                bundleID: { [self] objectID in
                    state.withLock { .success($0.bundleIDs[objectID]) }
                },
                isRunningInput: { [self] objectID in
                    inputReadContinuation?.yield()
                    return state.withLock { .success($0.runningInputs[objectID] ?? false) }
                },
                isRunningOutput: { [self] objectID in
                    state.withLock { .success($0.runningOutputs[objectID] ?? false) }
                },
                addListener: { [self] listener, _ in
                    listenerAddContinuation?.yield(listener.selector)
                    return state.withLock { state in
                        if state.failedAddSelectors.remove(listener.selector) != nil {
                            return kAudioHardwareUnspecifiedError
                        }
                        state.listeners[ListenerKey(objectID: listener.objectID, selector: listener.selector)] = StoredListener(value: listener)
                        return noErr
                    }
                },
                removeListener: { [self] listener, _ in
                    state.withLock { state in
                        state.listeners[ListenerKey(objectID: listener.objectID, selector: listener.selector)] = nil
                    }
                    return noErr
                }
            )
        }

        var activeSelectors: Set<AudioObjectPropertySelector> {
            state.withLock { Set($0.listeners.keys.map(\.selector)) }
        }

        var processListReadCount: Int {
            state.withLock(\.processListReadCount)
        }

        func configureProcess(bundleID: String, isRunningInput: Bool) {
            state.withLock { state in
                state.objectIDs = [processObjectID]
                state.pids[processObjectID] = 100
                state.bundleIDs[processObjectID] = bundleID
                state.runningInputs[processObjectID] = isRunningInput
                state.runningOutputs[processObjectID] = false
            }
        }

        func setRunningInput(_ isRunning: Bool) {
            state.withLock { $0.runningInputs[processObjectID] = isRunning }
        }

        func failNextAdd(selector: AudioObjectPropertySelector) {
            _ = state.withLock { $0.failedAddSelectors.insert(selector) }
        }

        func fireInputListener() {
            let key = ListenerKey(objectID: processObjectID, selector: kAudioProcessPropertyIsRunningInput)
            let listener = state.withLock { $0.listeners[key] }
            guard let listener else { return }
            var address = AudioProcessObjectQueries.globalAddress(kAudioProcessPropertyIsRunningInput)
            withUnsafePointer(to: &address) { listener.value.block(1, $0) }
        }
    }
#endif
