import CoreAudio
import Foundation
import os
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct AudioProcessActivityMonitorTests {
        @Test
        func publishesInitialAndChangedValuesWithoutDuplicates() async throws {
            let harness = AudioProcessActivityMonitorHarness()
            harness.configureProcess(bundleID: "us.zoom.caphost", isRunningInput: true)
            let monitor = AudioProcessActivityMonitor(dependencies: harness.dependencies, excludedPID: 999)
            let events = OSAllocatedUnfairLock(
                initialState: [AudioProcessActivityMonitor.RunningInputBundleIDsResult]()
            )

            let observerID = await monitor.addRunningInputObserver { result in
                events.withLock { $0.append(result) }
            }
            #expect(await pollUntil { harness.inputReadCount >= 1 })

            harness.fireInputListener()
            #expect(await pollUntil { harness.inputReadCount >= 2 })

            harness.setRunningInput(false)
            harness.fireInputListener()
            #expect(await pollUntil { harness.inputReadCount >= 3 })
            #expect(await pollUntil { events.withLock { $0.count >= 2 } })

            let values = events.withLock { $0 }
            #expect(values.count == 2)
            let initial = try #require(values.first)
            let changed = try #require(values.dropFirst().first)
            #expect((try? initial.get()) == Set(["us.zoom.caphost"]))
            #expect((try? changed.get()) == Set<String>())
            await monitor.removeRunningInputObserver(observerID)
        }

        @Test
        func refreshesCachedInputStateWhenCoreAudioDoesNotNotify() async throws {
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
            let initial = try #require(values.first)
            let changed = try #require(values.dropFirst().first)
            #expect((try? initial.get()) == Set<String>())
            #expect((try? changed.get()) == Set(["com.google.Chrome.helper"]))
            await monitor.removeRunningInputObserver(observerID)
        }

        @Test
        func disappearingInputProcessDoesNotInvalidateMeetingObservation() async throws {
            let harness = AudioProcessActivityMonitorHarness()
            harness.configureProcess(bundleID: "com.google.Chrome.helper", isRunningInput: true)
            let monitor = AudioProcessActivityMonitor(dependencies: harness.dependencies, excludedPID: 999)
            let events = OSAllocatedUnfairLock(
                initialState: [AudioProcessActivityMonitor.RunningInputBundleIDsResult]()
            )
            let observerID = await monitor.addRunningInputObserver { result in
                events.withLock { $0.append(result) }
            }

            // The input query can race CoreAudio's process-list notification when Meet exits.
            harness.removeProcess()
            await monitor.refreshRunningInputState()

            let values = events.withLock { $0 }
            #expect(values.count == 2)
            let ended = try #require(values.last)
            #expect((try? ended.get()) == Set<String>())
            #expect(harness.activeSelectors == [kAudioHardwarePropertyProcessObjectList])
            await monitor.removeRunningInputObserver(observerID)
        }

        @Test
        func disappearingUnrelatedProcessPreservesActiveMeeting() async throws {
            let harness = AudioProcessActivityMonitorHarness()
            harness.configureProcess(bundleID: "com.google.Chrome.helper", isRunningInput: true)
            harness.configureProcess(bundleID: "com.example.screenshot", isRunningInput: false, objectID: 43)
            let monitor = AudioProcessActivityMonitor(dependencies: harness.dependencies, excludedPID: 999)
            let events = OSAllocatedUnfairLock(
                initialState: [AudioProcessActivityMonitor.RunningInputBundleIDsResult]()
            )
            let observerID = await monitor.addRunningInputObserver { result in
                events.withLock { $0.append(result) }
            }

            harness.removeProcess(objectID: 43)
            await monitor.refreshRunningInputState()

            let values = events.withLock { $0 }
            #expect(values.count == 1)
            let latest = try #require(values.last)
            #expect((try? latest.get()) == Set(["com.google.Chrome.helper"]))
            #expect(harness.activeSelectors == [kAudioHardwarePropertyProcessObjectList, kAudioProcessPropertyIsRunningInput])
            await monitor.removeRunningInputObserver(observerID)
        }

        @Test
        func refreshQueriesRemainingInputsAfterProcessDisappears() async throws {
            let harness = AudioProcessActivityMonitorHarness()
            harness.configureProcess(bundleID: "com.example.screenshot", isRunningInput: false)
            harness.configureProcess(bundleID: "com.google.Chrome.helper", isRunningInput: false, objectID: 43)
            let monitor = AudioProcessActivityMonitor(dependencies: harness.dependencies, excludedPID: 999)
            let events = OSAllocatedUnfairLock(
                initialState: [AudioProcessActivityMonitor.RunningInputBundleIDsResult]()
            )
            let observerID = await monitor.addRunningInputObserver { result in
                events.withLock { $0.append(result) }
            }

            harness.removeProcess()
            harness.setRunningInput(true, objectID: 43)
            await monitor.refreshRunningInputState()

            let values = events.withLock { $0 }
            #expect(values.count == 2)
            let latest = try #require(values.last)
            #expect((try? latest.get()) == Set(["com.google.Chrome.helper"]))
            await monitor.removeRunningInputObserver(observerID)
        }

        @Test
        func disappearingProcessDuringRegistrationDoesNotHideOtherProcesses() async throws {
            let harness = AudioProcessActivityMonitorHarness()
            harness.configureProcess(bundleID: "com.example.screenshot", isRunningInput: false)
            harness.configureProcess(bundleID: "com.google.Chrome.helper", isRunningInput: true, objectID: 43)
            harness.failNextAdd(selector: kAudioProcessPropertyIsRunningInput, status: kAudioHardwareBadObjectError)
            let monitor = AudioProcessActivityMonitor(dependencies: harness.dependencies, excludedPID: 999)
            let events = OSAllocatedUnfairLock(
                initialState: [AudioProcessActivityMonitor.RunningInputBundleIDsResult]()
            )
            let observerID = await monitor.addRunningInputObserver { result in
                events.withLock { $0.append(result) }
            }

            let values = events.withLock { $0 }
            #expect(values.count == 1)
            let initial = try #require(values.first)
            #expect((try? initial.get()) == Set(["com.google.Chrome.helper"]))
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
        @Test(arguments: [false, true])
        func meetPWAStopsAfterAudioProcessDisappears(usesListener: Bool) async throws {
            let harness = AudioProcessActivityMonitorHarness()
            harness.configureProcess(bundleID: "com.google.Chrome.helper", isRunningInput: true)
            let activityMonitor = AudioProcessActivityMonitor(dependencies: harness.dependencies, excludedPID: 999)
            let now = ContinuousClock.now
            let currentInstant = OSAllocatedUnfairLock(initialState: now)
            let observations = OSAllocatedUnfairLock(initialState: [MeetingAudioActivityMonitor.Snapshot]())
            let queryFailed = OSAllocatedUnfairLock(initialState: false)
            let monitor = MeetingAudioActivityMonitor(
                pollInterval: .seconds(3600),
                activityMonitor: activityMonitor,
                now: { currentInstant.withLock { $0 } },
                sleepUntil: { deadline in currentInstant.withLock { $0 = deadline } }
            )
            await monitor.start(
                onChange: { snapshot in observations.withLock { $0.append(snapshot) } },
                onQueryFailure: { queryFailed.withLock { $0 = true } }
            )
            let initial = try #require(observations.withLock { $0.first })
            var tracker = MeetingRecordingActivityTracker()
            tracker.recordingDidStart(at: now, currentSnapshot: initial)
            for elapsed in [0, 30] {
                tracker.observeBrowserCorroboration(
                    browserContexts: [.chrome],
                    observedAudioContexts: initial.observedContexts,
                    at: now.advanced(by: .seconds(elapsed))
                )
            }

            currentInstant.withLock { $0 = now.advanced(by: .seconds(31)) }
            harness.removeProcess()
            if usesListener {
                harness.fireInputListener()
            } else {
                await activityMonitor.refreshRunningInputState()
            }
            #expect(await pollUntil {
                observations.withLock { $0.count >= 3 } || queryFailed.withLock { $0 }
            })
            await monitor.stop()

            #expect(!queryFailed.withLock { $0 })
            let ended = try #require(observations.withLock { $0.last })
            #expect(ended.endedContexts == [.chrome])
            #expect(ended.observedAt == now.advanced(by: .seconds(35)))
            let shouldStop = tracker.shouldStop(after: ended)
            #expect(shouldStop)
        }

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
            var failedAddSelectors = [AudioObjectPropertySelector: OSStatus]()
            var inputReadCount = 0
            var processListReadCount = 0
        }

        private let processObjectID = AudioObjectID(42)
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let listenerAddContinuation: AsyncStream<AudioObjectPropertySelector>.Continuation?

        init(
            listenerAddContinuation: AsyncStream<AudioObjectPropertySelector>.Continuation? = nil
        ) {
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
                    state.withLock { state in
                        state.inputReadCount += 1
                        guard let isRunning = state.runningInputs[objectID] else {
                            return .failure(AudioProcessObjectQueries.QueryFailure(
                                objectID: objectID,
                                selector: kAudioProcessPropertyIsRunningInput,
                                operation: .readData,
                                status: kAudioHardwareBadObjectError
                            ))
                        }
                        return .success(isRunning)
                    }
                },
                isRunningOutput: { [self] objectID in
                    state.withLock { .success($0.runningOutputs[objectID] ?? false) }
                },
                addListener: { [self] listener, _ in
                    listenerAddContinuation?.yield(listener.selector)
                    return state.withLock { state in
                        if let status = state.failedAddSelectors.removeValue(forKey: listener.selector) {
                            return status
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

        var inputReadCount: Int {
            state.withLock(\.inputReadCount)
        }

        func configureProcess(bundleID: String, isRunningInput: Bool, objectID: AudioObjectID = 42) {
            state.withLock { state in
                if !state.objectIDs.contains(objectID) { state.objectIDs.append(objectID) }
                state.pids[objectID] = 100
                state.bundleIDs[objectID] = bundleID
                state.runningInputs[objectID] = isRunningInput
                state.runningOutputs[objectID] = false
            }
        }

        func setRunningInput(_ isRunning: Bool, objectID: AudioObjectID = 42) {
            state.withLock { $0.runningInputs[objectID] = isRunning }
        }

        func removeProcess(objectID: AudioObjectID = 42) {
            state.withLock { state in
                state.objectIDs.removeAll { $0 == objectID }
                state.runningInputs[objectID] = nil
            }
        }

        func failNextAdd(selector: AudioObjectPropertySelector, status: OSStatus = kAudioHardwareUnspecifiedError) {
            state.withLock { $0.failedAddSelectors[selector] = status }
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
