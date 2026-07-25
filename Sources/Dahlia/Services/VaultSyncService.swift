import CoreServices
import DahliaRuntimeSupport
import Foundation
import GRDB

/// Tracks exported Summary paths under a Vault and imports one-time legacy Project descriptions.
/// Project identity and hierarchy are never inferred from filesystem state.
final class VaultSyncService: @unchecked Sendable {
    private let vaultURL: URL
    private let dbQueue: DatabaseQueue
    private let vaultId: UUID
    private let summaryPathSynchronizer: VaultSummaryPathSynchronizer
    private var stream: FSEventStreamRef?
    private let fileManager = FileManager.default
    private let callbackQueue = DispatchQueue(label: "com.dahlia.vault-sync", qos: .utility)
    private var initialMigrationRetryScheduled = false
    private var initialMigrationRetryAttempt = 0
    private var pendingEventBatches: [PendingEventBatch] = []
    private var eventRetryScheduled = false

    private struct PendingEventBatch {
        let paths: [String]
        let flags: [UInt32]
        var attempt = 0
    }

    init(vaultURL: URL, dbQueue: DatabaseQueue, vaultId: UUID) {
        self.vaultURL = vaultURL
        self.dbQueue = dbQueue
        self.vaultId = vaultId
        summaryPathSynchronizer = VaultSummaryPathSynchronizer(dbQueue: dbQueue, vaultId: vaultId)
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Initial Sync

    /// Performs one-time legacy metadata migration. Project hierarchy is never inferred from disk.
    func performInitialSync() {
        do {
            try withMutationLock {
                try migrateLegacyProjectDescriptions()
            }
            initialMigrationRetryAttempt = 0
        } catch is DahliaVaultMutationLockError {
            scheduleInitialMigrationRetry()
        } catch {
            initialMigrationRetryAttempt = 0
        }
    }

    /// CONTEXT.md の管理廃止に伴い、既存内容を一度だけ projects.description へ移行する。
    private func migrateLegacyProjectDescriptions() throws {
        let projects: [(id: UUID, name: String, description: String)]
        projects = try dbQueue.read { db in
            let pendingIds = try UUID.fetchSet(
                db,
                sql: "SELECT id FROM projects WHERE vaultId = ? AND legacyContextMigrated = 0",
                arguments: [self.vaultId]
            )
            return try ProjectRecord.fetchResolvedAll(vaultId: self.vaultId, in: db)
                .filter { pendingIds.contains($0.id) }
                .map {
                    (
                        id: $0.id,
                        name: $0.name,
                        description: $0.description
                    )
                }
        }

        let migrations = projects.map { project in
            let migratedDescription = project.description.isEmpty
                ? legacyProjectDescription(projectName: project.name)
                : project.description
            return (
                id: project.id,
                originalDescription: project.description,
                migratedDescription: migratedDescription
            )
        }

        try dbQueue.write { db in
            for migration in migrations {
                try db.execute(
                    sql: """
                    UPDATE projects
                    SET description = ?,
                        legacyContextMigrated = 1,
                        revision = revision + CASE WHEN description <> ? THEN 1 ELSE 0 END
                    WHERE id = ? AND legacyContextMigrated = 0 AND description = ?
                    """,
                    arguments: [
                        migration.migratedDescription,
                        migration.migratedDescription,
                        migration.id,
                        migration.originalDescription,
                    ]
                )
            }
        }
    }

    private func legacyProjectDescription(projectName: String) -> String {
        let projectURL = vaultURL.appending(path: projectName, directoryHint: .isDirectory)
        let contextURL = projectURL.appending(path: "CONTEXT.md")
        guard pathContainsNoSymlinks(projectURL),
              let values = try? contextURL.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .isSymbolicLinkKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              isInsideVaultAfterResolvingSymlinks(contextURL)
        else { return "" }
        guard let content = try? String(contentsOf: contextURL, encoding: .utf8) else { return "" }
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let openingTag = trimmedContent.range(of: "<context>"),
              let closingTag = trimmedContent.range(of: "</context>", range: openingTag.upperBound ..< trimmedContent.endIndex) else {
            return trimmedContent
        }
        return trimmedContent[openingTag.upperBound ..< closingTag.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pathContainsNoSymlinks(_ url: URL) -> Bool {
        let vault = vaultURL.standardizedFileURL
        let candidate = url.standardizedFileURL
        let relativeComponents = candidate.pathComponents.dropFirst(vault.pathComponents.count)
        guard candidate.pathComponents.starts(with: vault.pathComponents) else { return false }

        var current = vault
        for component in relativeComponents {
            current.append(path: component)
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else {
                return false
            }
        }
        return true
    }

    private func isInsideVaultAfterResolvingSymlinks(_ url: URL) -> Bool {
        let vaultPath = vaultURL.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath.hasPrefix(vaultPath.hasSuffix("/") ? vaultPath : vaultPath + "/")
    }

    // MARK: - FSEvents Monitoring

    func startMonitoring() {
        guard stream == nil else { return }

        let pathsToWatch = [vaultURL.path as CFString] as CFArray
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
                guard pendingEventBatches[0].attempt <= 5 else {
                    return
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
        let events = VaultFileSystemEventBatch(
            paths: paths,
            flags: flags,
            vaultURL: vaultURL,
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

    private func scheduleInitialMigrationRetry() {
        callbackQueue.async { [weak self] in
            guard let self,
                  !self.initialMigrationRetryScheduled,
                  self.initialMigrationRetryAttempt < 5 else { return }
            self.initialMigrationRetryScheduled = true
            self.initialMigrationRetryAttempt += 1
            let delay = min(pow(2, Double(self.initialMigrationRetryAttempt - 1)) * 0.1, 1.6)
            self.callbackQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.initialMigrationRetryScheduled = false
                self.performInitialSync()
            }
        }
    }

    private func withMutationLock<T>(_ operation: () throws -> T) throws -> T {
        try DahliaVaultMutationLock.withLock(vaultURL: vaultURL, vaultID: vaultId, operation: operation)
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
    let service = Unmanaged<VaultSyncService>.fromOpaque(info).takeUnretainedValue()

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
