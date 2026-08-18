import CoreAudio
import Foundation
import OSLog

actor AudioProcessActivityMonitor {
    typealias RunningInputBundleIDsResult = Result<Set<String>, AudioProcessObjectQueries.QueryFailure>
    typealias RunningInputChangeHandler = @Sendable (RunningInputBundleIDsResult) async -> Void

    /// CoreAudio listener blocks are retained and invoked only by CoreAudio and this monitor's actor-isolated lifecycle.
    struct PropertyListener: @unchecked Sendable {
        let objectID: AudioObjectID
        let selector: AudioObjectPropertySelector
        let block: AudioObjectPropertyListenerBlock
    }

    struct Dependencies: Sendable {
        let processObjectIDs: @Sendable () -> Result<[AudioObjectID], AudioProcessObjectQueries.QueryFailure>
        let pid: @Sendable (AudioObjectID) -> Result<pid_t, AudioProcessObjectQueries.QueryFailure>
        let bundleID: @Sendable (AudioObjectID) -> Result<String?, AudioProcessObjectQueries.QueryFailure>
        let isRunningInput: @Sendable (AudioObjectID) -> Result<Bool, AudioProcessObjectQueries.QueryFailure>
        let isRunningOutput: @Sendable (AudioObjectID) -> Result<Bool, AudioProcessObjectQueries.QueryFailure>
        let addListener: @Sendable (PropertyListener, DispatchQueue) -> OSStatus
        let removeListener: @Sendable (PropertyListener, DispatchQueue) -> OSStatus

        static let live: Self = {
            let queries = AudioProcessObjectQueries()
            return Self(
                processObjectIDs: queries.processObjectIDs,
                pid: queries.pid,
                bundleID: queries.bundleID,
                isRunningInput: queries.isRunningInput,
                isRunningOutput: queries.isRunningOutput,
                addListener: { listener, queue in
                    var address = AudioProcessObjectQueries.globalAddress(listener.selector)
                    return AudioObjectAddPropertyListenerBlock(listener.objectID, &address, queue, listener.block)
                },
                removeListener: { listener, queue in
                    var address = AudioProcessObjectQueries.globalAddress(listener.selector)
                    return AudioObjectRemovePropertyListenerBlock(listener.objectID, &address, queue, listener.block)
                }
            )
        }()
    }

    static let shared = AudioProcessActivityMonitor()

    private struct ProcessSnapshot: Equatable, Sendable {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String?
        var isRunningInput: Bool
        var isRunningOutput: Bool?

        var rendered: String {
            "objectID=\(objectID) pid=\(pid) bundleID=\(bundleID ?? "none") " +
                "input=\(isRunningInput) output=\(isRunningOutput.map(String.init) ?? "not-monitored")"
        }
    }

    private static let logger = Logger(subsystem: "com.dahlia", category: "AudioProcessActivity")
    private static let failureLogInterval: Duration = .seconds(60)

    private let dependencies: Dependencies
    private let excludedPID: pid_t
    private let retryInterval: Duration
    private let listenerQueue = DispatchQueue(label: "com.dahlia.audioProcessActivityListeners")
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: [PropertyListener]] = [:]
    private var snapshots: [AudioObjectID: ProcessSnapshot] = [:]
    private var runningInputObservers: [UUID: RunningInputChangeHandler] = [:]
    private var latestRunningInputBundleIDs: Set<String>?
    private var currentFailure: AudioProcessObjectQueries.QueryFailure?
    private var reconnectTask: Task<Void, Never>?
    private var nextFailureLogAt: ContinuousClock.Instant?
    private var debugMonitoring = false

    init(
        dependencies: Dependencies = .live,
        excludedPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        retryInterval: Duration = .seconds(1)
    ) {
        self.dependencies = dependencies
        self.excludedPID = excludedPID
        self.retryInterval = retryInterval
    }

    func isMonitoring() -> Bool {
        debugMonitoring
    }

    func startMonitoring() async {
        guard !debugMonitoring else { return }
        debugMonitoring = true
        log("monitor_started")

        if processListListener == nil {
            await connectIfNeeded()
        } else {
            await enableDebugOutputMonitoring()
        }
    }

    func stopMonitoring() {
        guard debugMonitoring else { return }
        debugMonitoring = false
        log("monitor_stopped")

        if runningInputObservers.isEmpty {
            stopCoreMonitoring()
        } else {
            disableDebugOutputMonitoring()
        }
    }

    func addRunningInputObserver(_ handler: @escaping RunningInputChangeHandler) async -> UUID {
        let id = UUID.v7()
        let wasInactive = !shouldMonitorCoreAudio
        runningInputObservers[id] = handler

        if wasInactive {
            await connectIfNeeded()
        } else if let latestRunningInputBundleIDs {
            await handler(.success(latestRunningInputBundleIDs))
        } else if let currentFailure {
            await handler(.failure(currentFailure))
        }
        return id
    }

    func removeRunningInputObserver(_ id: UUID) {
        runningInputObservers[id] = nil
        guard runningInputObservers.isEmpty, !debugMonitoring else { return }
        stopCoreMonitoring()
    }

    func refreshRunningInputState() async {
        guard shouldMonitorCoreAudio, processListListener != nil else { return }

        for objectID in snapshots.keys.sorted() {
            switch dependencies.isRunningInput(objectID) {
            case let .success(isRunning):
                snapshots[objectID]?.isRunningInput = isRunning
            case let .failure(failure):
                await monitoringFailed(failure)
                return
            }
        }
        await publishRunningInputBundleIDs()
    }
}

private extension AudioProcessActivityMonitor {
    var shouldMonitorCoreAudio: Bool {
        debugMonitoring || !runningInputObservers.isEmpty
    }

    private func connectIfNeeded() async {
        guard shouldMonitorCoreAudio, processListListener == nil else { return }
        reconnectTask?.cancel()
        reconnectTask = nil

        switch addProcessListListener() {
        case .success:
            await refreshProcessList(reason: "initial", forceNotification: true)
        case let .failure(failure):
            await monitoringFailed(failure)
        }
    }

    private func addProcessListListener() -> Result<Void, AudioProcessObjectQueries.QueryFailure> {
        let selector = kAudioHardwarePropertyProcessObjectList
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { await self.refreshProcessList(reason: "listener") }
        }
        let objectID = AudioObjectID(kAudioObjectSystemObject)
        let listener = PropertyListener(objectID: objectID, selector: selector, block: block)
        let status = dependencies.addListener(listener, listenerQueue)
        guard status == noErr else {
            return .failure(listenerFailure(objectID: objectID, selector: selector, status: status))
        }
        processListListener = block
        return .success(())
    }

    private func refreshProcessList(reason: String, forceNotification: Bool = false) async {
        guard shouldMonitorCoreAudio, processListListener != nil else { return }

        switch dependencies.processObjectIDs() {
        case let .success(objectIDs):
            let currentIDs = Set(objectIDs)
            let previousIDs = Set(processListeners.keys)
            let addedIDs = currentIDs.subtracting(previousIDs).sorted()
            let removedIDs = previousIDs.subtracting(currentIDs).sorted()

            if debugMonitoring {
                log(
                    "process_list_enumerated reason=\(reason) osStatus=\(noErr) count=\(objectIDs.count) " +
                        "added=\(renderedIDs(addedIDs)) removed=\(renderedIDs(removedIDs))"
                )
            }

            for objectID in removedIDs {
                let snapshot = snapshots.removeValue(forKey: objectID)
                removeProcessListeners(for: objectID)
                if debugMonitoring {
                    log("process_removed \(snapshot?.rendered ?? "objectID=\(objectID)")")
                }
            }

            for objectID in addedIDs {
                do {
                    let snapshot = try readSnapshot(for: objectID, includeOutput: debugMonitoring).get()
                    snapshots[objectID] = snapshot
                    try addProcessListener(for: objectID, selector: kAudioProcessPropertyIsRunningInput).get()
                    if debugMonitoring {
                        try addProcessListener(for: objectID, selector: kAudioProcessPropertyIsRunningOutput).get()
                        let eventName = reason == "initial" ? "process_initial" : "process_added"
                        log("\(eventName) \(snapshot.rendered)")
                    }
                } catch let failure {
                    await monitoringFailed(failure)
                    return
                }
            }

            await publishRunningInputBundleIDs(force: forceNotification)
        case let .failure(failure):
            await monitoringFailed(failure)
        }
    }

    private func enableDebugOutputMonitoring() async {
        for objectID in snapshots.keys.sorted() {
            guard processListeners[objectID]?.contains(where: { $0.selector == kAudioProcessPropertyIsRunningOutput }) != true else {
                continue
            }
            guard var snapshot = snapshots[objectID] else { continue }
            do {
                snapshot.isRunningOutput = try dependencies.isRunningOutput(objectID).get()
                snapshots[objectID] = snapshot
                try addProcessListener(for: objectID, selector: kAudioProcessPropertyIsRunningOutput).get()
                log("process_initial \(snapshot.rendered)")
            } catch let failure {
                await monitoringFailed(failure)
                return
            }
        }
    }

    private func disableDebugOutputMonitoring() {
        for objectID in Array(processListeners.keys) {
            removeProcessListeners(for: objectID, selector: kAudioProcessPropertyIsRunningOutput)
            snapshots[objectID]?.isRunningOutput = nil
        }
    }

    private func addProcessListener(
        for objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Result<Void, AudioProcessObjectQueries.QueryFailure> {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { await self.handleProcessPropertyChange(objectID: objectID, selector: selector) }
        }
        let listener = PropertyListener(objectID: objectID, selector: selector, block: block)
        let status = dependencies.addListener(listener, listenerQueue)
        guard status == noErr else {
            return .failure(listenerFailure(objectID: objectID, selector: selector, status: status))
        }
        processListeners[objectID, default: []].append(listener)
        if debugMonitoring {
            log("process_listener_added objectID=\(objectID) selector=\(selectorName(selector)) osStatus=\(status)")
        }
        return .success(())
    }

    private func handleProcessPropertyChange(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) async {
        guard shouldMonitorCoreAudio,
              processListeners[objectID]?.contains(where: { $0.selector == selector }) == true,
              var snapshot = snapshots[objectID] else { return }
        let previousSnapshot = snapshot

        switch selector {
        case kAudioProcessPropertyIsRunningInput:
            switch dependencies.isRunningInput(objectID) {
            case let .success(isRunning):
                snapshot.isRunningInput = isRunning
            case let .failure(failure):
                await monitoringFailed(failure)
                return
            }
        case kAudioProcessPropertyIsRunningOutput:
            switch dependencies.isRunningOutput(objectID) {
            case let .success(isRunning):
                snapshot.isRunningOutput = isRunning
            case let .failure(failure):
                await monitoringFailed(failure)
                return
            }
        default:
            return
        }

        snapshots[objectID] = snapshot
        if debugMonitoring {
            log(
                "process_state_listener_fired selector=\(selectorName(selector)) previous=\(previousSnapshot.rendered) " +
                    "current=\(snapshot.rendered) changed=\(previousSnapshot != snapshot)"
            )
        }
        if selector == kAudioProcessPropertyIsRunningInput {
            await publishRunningInputBundleIDs()
        }
    }

    private func readSnapshot(
        for objectID: AudioObjectID,
        includeOutput: Bool
    ) -> Result<ProcessSnapshot, AudioProcessObjectQueries.QueryFailure> {
        do {
            return try .success(ProcessSnapshot(
                objectID: objectID,
                pid: dependencies.pid(objectID).get(),
                bundleID: dependencies.bundleID(objectID).get(),
                isRunningInput: dependencies.isRunningInput(objectID).get(),
                isRunningOutput: includeOutput ? dependencies.isRunningOutput(objectID).get() : nil
            ))
        } catch let failure {
            return .failure(failure)
        }
    }

    private func publishRunningInputBundleIDs(force: Bool = false) async {
        let bundleIDs = Set(snapshots.values.compactMap { snapshot -> String? in
            guard snapshot.pid != excludedPID,
                  snapshot.isRunningInput,
                  let bundleID = snapshot.bundleID,
                  !bundleID.isEmpty else { return nil }
            return bundleID
        })
        guard force || bundleIDs != latestRunningInputBundleIDs else { return }
        latestRunningInputBundleIDs = bundleIDs
        currentFailure = nil

        let handlers = Array(runningInputObservers.values)
        for handler in handlers {
            await handler(.success(bundleIDs))
        }
    }

    private func monitoringFailed(_ failure: AudioProcessObjectQueries.QueryFailure) async {
        let shouldNotify = currentFailure == nil
        removeAllListeners()
        snapshots.removeAll()
        latestRunningInputBundleIDs = nil
        currentFailure = failure
        let failureTime = ContinuousClock.now
        if nextFailureLogAt.map({ failureTime < $0 }) != true {
            nextFailureLogAt = failureTime.advanced(by: Self.failureLogInterval)
            log("monitor_failed \(failure.description)", level: .error)
        }

        if shouldNotify {
            let handlers = Array(runningInputObservers.values)
            for handler in handlers {
                await handler(.failure(failure))
            }
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldMonitorCoreAudio, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self, retryInterval] in
            do {
                try await Task.sleep(for: retryInterval)
            } catch {
                return
            }
            await self?.reconnect()
        }
    }

    private func reconnect() async {
        reconnectTask = nil
        await connectIfNeeded()
    }

    private func stopCoreMonitoring() {
        reconnectTask?.cancel()
        reconnectTask = nil
        removeAllListeners()
        snapshots.removeAll()
        latestRunningInputBundleIDs = nil
        currentFailure = nil
        nextFailureLogAt = nil
    }

    private func removeAllListeners() {
        for objectID in Array(processListeners.keys) {
            removeProcessListeners(for: objectID)
        }
        processListeners.removeAll()

        guard let block = processListListener else { return }
        let objectID = AudioObjectID(kAudioObjectSystemObject)
        let selector = kAudioHardwarePropertyProcessObjectList
        let listener = PropertyListener(objectID: objectID, selector: selector, block: block)
        let status = dependencies.removeListener(listener, listenerQueue)
        log("process_list_listener_removed osStatus=\(status)", level: status == noErr ? .info : .error)
        processListListener = nil
    }

    private func removeProcessListeners(
        for objectID: AudioObjectID,
        selector: AudioObjectPropertySelector? = nil
    ) {
        guard let listeners = processListeners[objectID] else { return }
        let removedListeners = listeners.filter { selector == nil || $0.selector == selector }
        let retainedListeners = listeners.filter { selector != nil && $0.selector != selector }

        for listener in removedListeners {
            let status = dependencies.removeListener(listener, listenerQueue)
            if debugMonitoring {
                log(
                    "process_listener_removed objectID=\(objectID) selector=\(selectorName(listener.selector)) osStatus=\(status)",
                    level: status == noErr ? .info : .error
                )
            }
        }

        if retainedListeners.isEmpty {
            processListeners[objectID] = nil
        } else {
            processListeners[objectID] = retainedListeners
        }
    }

    private func listenerFailure(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        status: OSStatus
    ) -> AudioProcessObjectQueries.QueryFailure {
        AudioProcessObjectQueries.QueryFailure(
            objectID: objectID,
            selector: selector,
            operation: .addListener,
            status: status
        )
    }

    private func renderedIDs(_ objectIDs: [AudioObjectID]) -> String {
        let values = objectIDs.map(String.init).joined(separator: ",")
        return "[\(values)]"
    }

    private func selectorName(_ selector: AudioObjectPropertySelector) -> String {
        switch selector {
        case kAudioProcessPropertyIsRunningInput:
            "isRunningInput"
        case kAudioProcessPropertyIsRunningOutput:
            "isRunningOutput"
        default:
            String(selector)
        }
    }

    private func log(_ message: String, level: OSLogType = .info) {
        switch level {
        case .error:
            Self.logger.error("\(message, privacy: .public)")
        default:
            Self.logger.info("\(message, privacy: .public)")
        }
    }
}
