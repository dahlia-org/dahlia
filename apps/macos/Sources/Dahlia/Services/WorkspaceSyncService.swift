import CoreServices
import DahliaRuntimeSupport
import Foundation
import GRDB

/// Tracks exported Summary paths under a Workspace.
/// Project identity and hierarchy are never inferred from filesystem state.
final class WorkspaceSyncService: @unchecked Sendable {
    private let workspaceURL: URL
    private let dbQueue: DatabaseQueue
    private let workspaceId: UUID
    private let summaryPathSynchronizer: WorkspaceSummaryPathSynchronizer
    private let maximumEventRetryAttempts: Int
    private var stream: FSEventStreamRef?
    private let fileManager = FileManager.default
    private let callbackQueue = DispatchQueue(label: "com.dahlia.workspace-sync", qos: .utility)
    private var pendingEventBatches: [PendingEventBatch] = []
    private var eventRetryScheduled = false

    private struct PendingEventBatch {
        let paths: [String]
        let flags: [UInt32]
        var attempt = 0
    }

    init(
        workspaceURL: URL,
        dbQueue: DatabaseQueue,
        workspaceId: UUID,
        maximumEventRetryAttempts: Int = 5
    ) {
        self.workspaceURL = workspaceURL
        self.dbQueue = dbQueue
        self.workspaceId = workspaceId
        self.maximumEventRetryAttempts = maximumEventRetryAttempts
        summaryPathSynchronizer = WorkspaceSummaryPathSynchronizer(dbQueue: dbQueue, workspaceId: workspaceId)
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - FSEvents Monitoring

    func startMonitoring() {
        guard stream == nil else { return }

        let pathsToWatch = [workspaceURL.path as CFString] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagUseCFTypes)

        guard let eventStream = FSEventStreamCreate(
            nil,
            fsEventsCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(eventStream, callbackQueue)
        FSEventStreamStart(eventStream)
        stream = eventStream
    }

    func stopMonitoring() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - FSEvents Handler

    func handleEvents(paths: [String], flags: [UInt32]) {
        pendingEventBatches.append(PendingEventBatch(paths: paths, flags: flags))
        processPendingEventBatches()
    }

    private func processPendingEventBatches() {
        guard !eventRetryScheduled else { return }
        while !pendingEventBatches.isEmpty {
            let pending = pendingEventBatches[0]
            do {
                try applyEventBatch(paths: pending.paths, flags: pending.flags)
                pendingEventBatches.removeFirst()
            } catch {
                pendingEventBatches[0].attempt += 1
                guard pendingEventBatches[0].attempt <= maximumEventRetryAttempts else {
                    pendingEventBatches.removeFirst()
                    ErrorReportingService.capture(error, context: ["source": "workspaceSummaryPathSync"])
                    continue
                }
                eventRetryScheduled = true
                let delay = min(pow(2, Double(pendingEventBatches[0].attempt - 1)) * 0.1, 1.6)
                callbackQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    self.eventRetryScheduled = false
                    self.processPendingEventBatches()
                }
                return
            }
        }
    }

    private func applyEventBatch(paths: [String], flags: [UInt32]) throws {
        let events = WorkspaceFileSystemEventBatch(
            paths: paths,
            flags: flags,
            workspaceURL: workspaceURL,
            fileManager: fileManager
        )
        try withMutationLock {
            for rename in events.directoryRenames {
                try dbQueue.write { db in
                    try summaryPathSynchronizer.renamePathsByPrefix(
                        oldPrefix: rename.oldPath,
                        newPrefix: rename.newPath,
                        in: db
                    )
                }
            }
            for rename in events.summaryRenames {
                try summaryPathSynchronizer.renamePath(from: rename.oldPath, to: rename.newPath)
            }

            try summaryPathSynchronizer.clearRemovedPathPrefixes(events.removedDirectories)
            try summaryPathSynchronizer.clearRemovedPaths(events.removedSummaryPaths)
        }
    }

    private func withMutationLock<T>(_ operation: () throws -> T) throws -> T {
        try DahliaWorkspaceMutationLock.withLock(workspaceURL: workspaceURL, workspaceID: workspaceId, operation: operation)
    }
}

// MARK: - C Callback

private func fsEventsCallback(
    streamRef _: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds _: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let service = Unmanaged<WorkspaceSyncService>.fromOpaque(info).takeUnretainedValue()

    let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    var paths: [String] = []
    var flags: [UInt32] = []

    for i in 0 ..< numEvents {
        if let cfPath = CFArrayGetValueAtIndex(cfPaths, i) {
            let path = Unmanaged<CFString>.fromOpaque(cfPath).takeUnretainedValue() as String
            paths.append(path)
            flags.append(eventFlags[i])
        }
    }

    service.handleEvents(paths: paths, flags: flags)
}
