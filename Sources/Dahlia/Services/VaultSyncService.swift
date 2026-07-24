import CoreServices
import DahliaRuntimeSupport
import Foundation
import GRDB

/// 保管庫ディレクトリとの同期を管理する。
/// アプリ起動時の一括同期と FSEvents によるリアルタイム監視を提供する。
final class VaultSyncService: @unchecked Sendable {
    private let vaultURL: URL
    private let dbQueue: DatabaseQueue
    private let vaultId: UUID
    private let summaryPathSynchronizer: VaultSummaryPathSynchronizer
    private var stream: FSEventStreamRef?
    private let fileManager = FileManager.default
    private let callbackQueue = DispatchQueue(label: "com.dahlia.vault-sync", qos: .utility)
    private var reconciliationScheduled = false
    private var reconciliationAttempt = 0
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

    /// vault 内の全ディレクトリをスキャンし、projects テーブルと同期する。
    func performInitialSync() {
        do {
            try withMutationLock {
                let diskNames = Set(scanAllDirectoryNames())
                try dbQueue.write { db in
                    let before = try ProjectRecord.fetchResolvedAll(vaultId: self.vaultId, in: db)
                    try ProjectRecord.upsertAll(paths: Array(diskNames), vaultId: self.vaultId, in: db)
                    let after = try ProjectRecord.fetchResolvedAll(vaultId: self.vaultId, in: db)
                    try self.synchronizeChangedPathCasing(before: before, after: after, in: db)
                    try self.reconcileMissingProjects(diskNames: diskNames, in: db)
                }
                try migrateLegacyProjectDescriptions()
            }
            reconciliationAttempt = 0
        } catch is DahliaVaultMutationLockError {
            scheduleFullReconciliation()
        } catch {
            reconciliationAttempt = 0
        }
    }

    /// CONTEXT.md の管理廃止に伴い、既存内容を一度だけ projects.description へ移行する。
    private func migrateLegacyProjectDescriptions() throws {
        let projects: [(id: UUID, name: String, description: String, missingOnDisk: Bool)]
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
                        description: $0.description,
                        missingOnDisk: $0.missingOnDisk
                    )
                }
        }

        let migrations = projects.map { project in
            let migratedDescription = project.description.isEmpty && !project.missingOnDisk
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

    /// DB 内のプロジェクトとディスク上のフォルダを突合し、不整合を解消する。
    /// Missing directories never delete Project metadata; they only update missingOnDisk.
    private func reconcileMissingProjects(diskNames: Set<String>, in db: Database) throws {
        let allProjects = try ProjectRecord.fetchResolvedAll(vaultId: self.vaultId, in: db)
        let diskKeys = Set(diskNames.map(ProjectRecord.pathKey))
        var missingIds: Set<UUID> = []
        var restoredIds: Set<UUID> = []
        for project in allProjects {
            let onDisk = diskKeys.contains(ProjectRecord.pathKey(project.name))
            if !onDisk, !project.missingOnDisk {
                missingIds.insert(project.id)
            } else if onDisk, project.missingOnDisk {
                restoredIds.insert(project.id)
            }
        }
        try ProjectRecord.setMissing(ids: missingIds, missing: true, in: db)
        try ProjectRecord.setMissing(ids: restoredIds, missing: false, in: db)
    }

    private func synchronizeChangedPathCasing(
        before: [ProjectRecord],
        after: [ProjectRecord],
        in db: Database
    ) throws {
        let beforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        let afterByID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        let changed = after.filter { project in
            beforeByID[project.id]?.leafName != project.leafName
        }.sorted {
            $0.name.split(separator: "/").count < $1.name.split(separator: "/").count
        }

        for project in changed {
            guard let oldProject = beforeByID[project.id] else { continue }
            let newParentPath = project.parentProjectId.flatMap { afterByID[$0]?.name }
            let sourcePath = newParentPath.map { "\($0)/\(oldProject.leafName)" } ?? oldProject.leafName
            try summaryPathSynchronizer.renamePathsByPrefix(
                oldPrefix: sourcePath,
                newPrefix: project.name,
                in: db
            )
        }
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

    // MARK: - Directory Scanning

    func scanAllDirectoryNames() -> [String] {
        var names: [String] = []
        let vaultPath = vaultURL.resolvingSymlinksInPath().standardizedFileURL.path
        let vaultPrefix = vaultPath.hasSuffix("/") ? vaultPath : vaultPath + "/"

        guard let enumerator = fileManager.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            let lastComponent = url.lastPathComponent
            if lastComponent.hasPrefix("_") || lastComponent.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }

            let fullPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard fullPath.hasPrefix(vaultPrefix) else { continue }
            let relativePath = String(fullPath.dropFirst(vaultPrefix.count))
            if !relativePath.isEmpty {
                names.append(relativePath)
            }
        }

        return names
    }

    // MARK: - DB Operations (direct, non-MainActor)

    private func upsertProjects(names: [String]) throws {
        guard !names.isEmpty else { return }
        try dbQueue.write { db in
            try ProjectRecord.upsertAll(paths: names, vaultId: self.vaultId, in: db)
        }
    }

    private func renameProjectsByPrefix(oldPrefix: String, newPrefix: String) throws {
        try dbQueue.write { db in
            var records = try ProjectRecord.fetchResolvedAll(vaultId: self.vaultId, in: db)
            guard var project = records.first(where: { $0.name == oldPrefix }) else { return }
            let components = newPrefix.split(separator: "/")
            guard let leafName = components.last else { return }
            let parentPath = components.dropLast().joined(separator: "/")
            if !parentPath.isEmpty, !records.contains(where: { $0.name == parentPath }) {
                try ProjectRecord.upsertAll(paths: [parentPath], vaultId: self.vaultId, in: db)
                records = try ProjectRecord.fetchResolvedAll(vaultId: self.vaultId, in: db)
            }
            let effectiveType = ProjectRecord.effectiveType(for: project.id, records: records)?.type ?? .undefined
            project.parentProjectId = parentPath.isEmpty
                ? nil
                : records.first(where: { $0.name == parentPath })?.id
            project.leafName = String(leafName)
            project.projectType = project.parentProjectId == nil ? effectiveType : nil
            project.revision += 1
            try project.update(db)
            let descendants = try Set(
                ProjectRecord.hierarchy(projectId: project.id, vaultId: self.vaultId, in: db)
                    .dropFirst()
                    .map(\.id)
            )
            try ProjectRecord.incrementRevisions(descendants, in: db)
            try summaryPathSynchronizer.renamePathsByPrefix(oldPrefix: oldPrefix, newPrefix: newPrefix, in: db)
        }
    }

    /// Removed directories retain every Project row and mark the complete subtree missing.
    private func handleDirectoryRemovals(_ relativePaths: [String], in db: Database) throws {
        guard !relativePaths.isEmpty else { return }

        let allProjects = try ProjectRecord.fetchResolvedAll(vaultId: self.vaultId, in: db)

        for relativePath in relativePaths {
            let restoredURL = vaultURL.appending(path: relativePath, directoryHint: .isDirectory)
            guard !fileManager.fileExists(atPath: restoredURL.path) else { continue }
            let matching = allProjects.filter {
                ProjectRecord.belongsToHierarchy($0.name, prefix: relativePath)
            }
            try ProjectRecord.setMissing(ids: Set(matching.map(\.id)), missing: true, in: db)
        }
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
                try renameProjectsByPrefix(oldPrefix: rename.oldPath, newPrefix: rename.newPath)
            }
            for rename in events.summaryRenames {
                try summaryPathSynchronizer.renamePath(from: rename.oldPath, to: rename.newPath)
            }

            if !events.removedDirectories.isEmpty {
                try dbQueue.write { db in
                    try self.handleDirectoryRemovals(events.removedDirectories, in: db)
                }
            }

            if !events.newDirectories.isEmpty {
                var allNames: Set<String> = []
                for directory in events.newDirectories {
                    for path in ProjectRecord.allIntermediatePaths(for: directory) {
                        allNames.insert(path)
                    }
                }
                try upsertProjects(names: Array(allNames))
            }

            try summaryPathSynchronizer.clearRemovedPaths(events.removedSummaryPaths)
        }
    }

    private func scheduleFullReconciliation() {
        callbackQueue.async { [weak self] in
            guard let self,
                  !self.reconciliationScheduled,
                  self.reconciliationAttempt < 5 else { return }
            self.reconciliationScheduled = true
            self.reconciliationAttempt += 1
            let delay = min(pow(2, Double(self.reconciliationAttempt - 1)) * 0.1, 1.6)
            self.callbackQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.reconciliationScheduled = false
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
