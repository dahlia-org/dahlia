import CoreServices
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
        let diskNames = Set(scanAllDirectoryNames())
        try? dbQueue.write { db in
            try ProjectRecord.upsertAll(names: Array(diskNames), vaultId: self.vaultId, in: db)
            try self.reconcileMissingProjects(diskNames: diskNames, in: db)
        }
        migrateLegacyProjectDescriptions()
    }

    /// CONTEXT.md の管理廃止に伴い、既存内容を一度だけ projects.description へ移行する。
    private func migrateLegacyProjectDescriptions() {
        let projects: [(id: UUID, name: String, description: String)]
        do {
            projects = try dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, name, description
                    FROM projects
                    WHERE vaultId = ? AND legacyContextMigrated = 0
                    """,
                    arguments: [self.vaultId]
                ).map { row in
                    (id: row["id"], name: row["name"], description: row["description"])
                }
            }
        } catch {
            return
        }

        let migrations = projects.map { project in
            let description = project.description.isEmpty
                ? legacyProjectDescription(projectName: project.name)
                : project.description
            return (id: project.id, description: description)
        }

        try? dbQueue.write { db in
            for migration in migrations {
                try db.execute(
                    sql: """
                    UPDATE projects
                    SET description = ?, legacyContextMigrated = 1
                    WHERE id = ? AND legacyContextMigrated = 0
                    """,
                    arguments: [migration.description, migration.id]
                )
            }
        }
    }

    private func legacyProjectDescription(projectName: String) -> String {
        let contextURL = vaultURL
            .appending(path: projectName, directoryHint: .isDirectory)
            .appending(path: "CONTEXT.md")
        guard let content = try? String(contentsOf: contextURL, encoding: .utf8) else { return "" }
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let openingTag = trimmedContent.range(of: "<context>"),
              let closingTag = trimmedContent.range(of: "</context>", range: openingTag.upperBound ..< trimmedContent.endIndex) else {
            return trimmedContent
        }
        return trimmedContent[openingTag.upperBound ..< closingTag.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// DB 内のプロジェクトとディスク上のフォルダを突合し、不整合を解消する。
    /// meeting を持たない孤立プロジェクトは削除、持つものは missingOnDisk フラグを設定する。
    private func reconcileMissingProjects(diskNames: Set<String>, in db: Database) throws {
        let allProjects = try ProjectRecord
            .filter(Column("vaultId") == self.vaultId)
            .fetchAll(db)

        // meeting を持つプロジェクト ID を一括取得（N+1 回避）
        let idsWithMeetings = try UUID.fetchSet(db, sql: """
        SELECT DISTINCT projectId FROM meetings
        WHERE projectId IN (SELECT id FROM projects WHERE vaultId = ?)
        """, arguments: [self.vaultId])

        for project in allProjects {
            let onDisk = diskNames.contains(project.name)
            let shouldBeMissing = !onDisk

            if shouldBeMissing {
                if idsWithMeetings.contains(project.id) {
                    if !project.missingOnDisk {
                        var updated = project
                        updated.missingOnDisk = true
                        try updated.update(db)
                    }
                } else {
                    try project.delete(db)
                }
            } else if project.missingOnDisk {
                var updated = project
                updated.missingOnDisk = false
                try updated.update(db)
            }
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
        let vaultPath = vaultURL.path

        guard let enumerator = fileManager.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else { continue }

            let lastComponent = url.lastPathComponent
            if lastComponent.hasPrefix("_") || lastComponent.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }

            let fullPath = url.path
            guard fullPath.count > vaultPath.count + 1 else { continue }
            let relativePath = String(fullPath.dropFirst(vaultPath.count + 1))
            if !relativePath.isEmpty {
                names.append(relativePath)
            }
        }

        return names
    }

    // MARK: - DB Operations (direct, non-MainActor)

    private func upsertProjects(names: [String]) {
        guard !names.isEmpty else { return }
        try? dbQueue.write { db in
            try ProjectRecord.upsertAll(names: names, vaultId: self.vaultId, in: db)
            // 復活したフォルダの missingOnDisk を一括クリア
            try db.execute(
                sql: "UPDATE projects SET missingOnDisk = 0 WHERE vaultId = ? AND missingOnDisk = 1",
                arguments: [self.vaultId]
            )
        }
    }

    private func renameProjectsByPrefix(oldPrefix: String, newPrefix: String) {
        try? dbQueue.write { db in
            try ProjectRecord.renameByPrefix(oldPrefix: oldPrefix, newPrefix: newPrefix, vaultId: self.vaultId, in: db)
            try summaryPathSynchronizer.renamePathsByPrefix(oldPrefix: oldPrefix, newPrefix: newPrefix, in: db)
        }
    }

    /// 削除されたフォルダ群を一括処理する。meeting ありなら missingOnDisk、なしなら DB 削除。
    private func handleDirectoryRemovals(_ relativePaths: [String], in db: Database) throws {
        guard !relativePaths.isEmpty else { return }

        // meeting を持つプロジェクト ID を一括取得（N+1 回避）
        let idsWithMeetings = try UUID.fetchSet(db, sql: """
        SELECT DISTINCT projectId FROM meetings
        WHERE projectId IN (SELECT id FROM projects WHERE vaultId = ?)
        """, arguments: [self.vaultId])

        let allProjects = try ProjectRecord
            .filter(Column("vaultId") == self.vaultId)
            .fetchAll(db)

        for relativePath in relativePaths {
            let restoredURL = vaultURL.appending(path: relativePath, directoryHint: .isDirectory)
            guard !fileManager.fileExists(atPath: restoredURL.path) else { continue }
            let matching = allProjects.filter {
                ProjectRecord.belongsToHierarchy($0.name, prefix: relativePath)
            }
            let hasTranscripts = matching.contains { idsWithMeetings.contains($0.id) }

            if hasTranscripts {
                try ProjectRecord.setMissingByPrefix(relativePath, missing: true, vaultId: self.vaultId, in: db)
            } else {
                try ProjectRecord.deleteByPrefix(relativePath, vaultId: self.vaultId, in: db)
            }
        }
    }

    // MARK: - FSEvents Handler

    func handleEvents(paths: [String], flags: [UInt32]) {
        let events = VaultFileSystemEventBatch(paths: paths, flags: flags, vaultURL: vaultURL, fileManager: fileManager)
        for rename in events.directoryRenames {
            renameProjectsByPrefix(oldPrefix: rename.oldPath, newPrefix: rename.newPath)
        }
        for rename in events.summaryRenames {
            summaryPathSynchronizer.renamePath(from: rename.oldPath, to: rename.newPath)
        }

        if !events.removedDirectories.isEmpty {
            try? dbQueue.write { db in
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
            upsertProjects(names: Array(allNames))
        }

        summaryPathSynchronizer.clearRemovedPaths(events.removedSummaryPaths)
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
