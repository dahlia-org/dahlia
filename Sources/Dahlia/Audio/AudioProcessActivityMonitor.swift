import CoreAudio
import Foundation
import OSLog

actor AudioProcessActivityMonitor {
    static let shared = AudioProcessActivityMonitor()

    private struct ProcessSnapshot: Equatable, Sendable {
        let objectID: AudioObjectID
        let pid: String
        let bundleID: String
        let isRunningInput: String
        let isRunningOutput: String

        var rendered: String {
            "objectID=\(objectID) pid=\(pid) bundleID=\(bundleID) input=\(isRunningInput) output=\(isRunningOutput)"
        }
    }

    private struct ProcessListener {
        let selector: AudioObjectPropertySelector
        let block: AudioObjectPropertyListenerBlock
    }

    private static let logger = Logger(subsystem: "com.dahlia", category: "AudioProcessActivity")

    private let queries = AudioProcessObjectQueries()
    private let listenerQueue = DispatchQueue(label: "com.dahlia.audioProcessActivityListeners")
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: [ProcessListener]] = [:]
    private var snapshots: [AudioObjectID: ProcessSnapshot] = [:]
    private var monitoring = false

    func isMonitoring() -> Bool {
        monitoring
    }

    func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true

        let listListenerStatus = addProcessListListener()
        log("monitor_started processListListenerOSStatus=\(listListenerStatus)")
        refreshProcessList(reason: "initial")
    }

    func stopMonitoring() {
        guard monitoring else { return }
        monitoring = false
        removeAllListeners()
        snapshots.removeAll()
        log("monitor_stopped")
    }

    private func addProcessListListener() -> OSStatus {
        var address = AudioProcessObjectQueries.globalAddress(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { await self.refreshProcessList(reason: "listener") }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
        if status == noErr {
            processListListener = block
        }
        return status
    }

    private func refreshProcessList(reason: String) {
        guard monitoring else { return }

        switch queries.processObjectIDs() {
        case let .success(objectIDs):
            let currentIDs = Set(objectIDs)
            let previousIDs = Set(processListeners.keys)
            let addedIDs = currentIDs.subtracting(previousIDs).sorted()
            let removedIDs = previousIDs.subtracting(currentIDs).sorted()
            log(
                "process_list_enumerated reason=\(reason) osStatus=\(noErr) count=\(objectIDs.count) " +
                    "added=\(renderedIDs(addedIDs)) removed=\(renderedIDs(removedIDs))"
            )

            for objectID in removedIDs {
                let snapshot = snapshots.removeValue(forKey: objectID)
                removeProcessListeners(for: objectID)
                log("process_removed \(snapshot?.rendered ?? "objectID=\(objectID)")")
            }

            for objectID in addedIDs {
                let snapshot = readSnapshot(for: objectID)
                snapshots[objectID] = snapshot
                let eventName = reason == "initial" ? "process_initial" : "process_added"
                log("\(eventName) \(snapshot.rendered)")
                addProcessListeners(for: objectID)
            }
        case let .failure(failure):
            log("process_list_query_failed \(failure.description)", level: .error)
        }
    }

    private func addProcessListeners(for objectID: AudioObjectID) {
        let selectors = [
            kAudioProcessPropertyIsRunningInput,
            kAudioProcessPropertyIsRunningOutput,
        ]
        for selector in selectors {
            var address = AudioProcessObjectQueries.globalAddress(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                Task { await self.handleProcessPropertyChange(objectID: objectID, selector: selector) }
            }
            let status = AudioObjectAddPropertyListenerBlock(objectID, &address, listenerQueue, block)
            log(
                "process_listener_added objectID=\(objectID) selector=\(selectorName(selector)) osStatus=\(status)",
                level: status == noErr ? .info : .error
            )
            if status == noErr {
                processListeners[objectID, default: []].append(ProcessListener(selector: selector, block: block))
            }
        }
        if processListeners[objectID] == nil {
            processListeners[objectID] = []
        }
    }

    private func handleProcessPropertyChange(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) {
        guard monitoring, processListeners[objectID] != nil else { return }
        let previousSnapshot = snapshots[objectID]
        let currentSnapshot = readSnapshot(for: objectID)
        snapshots[objectID] = currentSnapshot
        log(
            "process_state_listener_fired selector=\(selectorName(selector)) previous=\(previousSnapshot?.rendered ?? "none") " +
                "current=\(currentSnapshot.rendered) changed=\(previousSnapshot != currentSnapshot)"
        )
    }

    private func readSnapshot(for objectID: AudioObjectID) -> ProcessSnapshot {
        ProcessSnapshot(
            objectID: objectID,
            pid: renderedPID(queries.pid(for: objectID)),
            bundleID: renderedBundleID(queries.bundleID(for: objectID)),
            isRunningInput: renderedRunningState(queries.isRunningInput(for: objectID)),
            isRunningOutput: renderedRunningState(queries.isRunningOutput(for: objectID))
        )
    }

    private func removeAllListeners() {
        for objectID in Array(processListeners.keys) {
            removeProcessListeners(for: objectID)
        }
        processListeners.removeAll()

        guard let block = processListListener else { return }
        var address = AudioProcessObjectQueries.globalAddress(kAudioHardwarePropertyProcessObjectList)
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
        log("process_list_listener_removed osStatus=\(status)", level: status == noErr ? .info : .error)
        processListListener = nil
    }

    private func removeProcessListeners(for objectID: AudioObjectID) {
        guard let listeners = processListeners.removeValue(forKey: objectID) else { return }
        for listener in listeners {
            var address = AudioProcessObjectQueries.globalAddress(listener.selector)
            let status = AudioObjectRemovePropertyListenerBlock(objectID, &address, listenerQueue, listener.block)
            log(
                "process_listener_removed objectID=\(objectID) selector=\(selectorName(listener.selector)) osStatus=\(status)",
                level: status == noErr ? .info : .error
            )
        }
    }

    private func renderedPID(_ result: Result<pid_t, AudioProcessObjectQueries.QueryFailure>) -> String {
        switch result {
        case let .success(value):
            String(value)
        case let .failure(failure):
            "error(\(failure.description))"
        }
    }

    private func renderedBundleID(_ result: Result<String?, AudioProcessObjectQueries.QueryFailure>) -> String {
        switch result {
        case let .success(value):
            value ?? "none"
        case let .failure(failure):
            "error(\(failure.description))"
        }
    }

    private func renderedRunningState(_ result: Result<Bool, AudioProcessObjectQueries.QueryFailure>) -> String {
        switch result {
        case let .success(value):
            String(value)
        case let .failure(failure):
            "error(\(failure.description))"
        }
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
