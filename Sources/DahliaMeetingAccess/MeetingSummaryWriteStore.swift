import DahliaRuntimeSupport
import Foundation
import GRDB

enum SummaryWriteLimits {
    static let documentBytes = 256 * 1024
    static let sections = 200
    static let blocksPerSection = 500
    /// アプリの生成経路と同じ既定タグ色。
    static let generatedTagColorHex = "#808080"
}

public extension MeetingAccessStore {
    /// 保存済みサマリーをドキュメント全体の置換で更新する。
    ///
    /// ADR-0010 の Summary 変更手順に従い、Vault ロックを取り、完全に事前検証してから
    /// ファイルを書き、単一トランザクションでデータベースを更新し、失敗時はファイルを書き戻す。
    func updateMeetingSummary(
        meetingID: UUID,
        expectedDocumentVersion: String,
        document: SummaryDocument
    ) throws -> SummaryMutationResult {
        try requireWriteAccess()

        let vault = try database.read(summaryVault(in:))
        return try withVaultMutationLock(vaultURL: vault.url) { () throws -> SummaryMutationResult in
            let plan = try database.read { db in
                try makeSummaryUpdatePlan(
                    meetingID: meetingID,
                    expectedDocumentVersion: expectedDocumentVersion,
                    document: document,
                    vaultURL: vault.url,
                    in: db
                )
            }

            switch plan {
            case let .unchanged(result):
                return result
            case let .apply(update):
                return try writingVaultFile(update) { () throws -> SummaryMutationResult in
                    try database.write { db in
                        try commitSummaryUpdate(update, in: db)
                    }
                    DahliaWorkspaceChangeNotification.post(vaultID: vaultID)
                    return update.result
                }
            }
        }
    }
}

extension MeetingAccessStore {
    enum SummaryUpdatePlan {
        case unchanged(SummaryMutationResult)
        case apply(SummaryUpdate)
    }

    struct SummaryUpdate {
        let meetingID: UUID
        let storedDocument: String
        let summaryTitle: String
        let meetingName: String?
        let meetingDescription: String?
        let tags: [String]
        /// 書き戻す Vault の Markdown。書き出し記録がない、または到達できない場合は nil。
        let vaultFile: VaultFileWrite?
        let result: SummaryMutationResult
    }

    struct VaultFileWrite {
        let fileURL: URL
        let relativePath: String
        let markdown: String
        let previousContents: Data?
    }

    struct SummaryVault {
        let id: UUID
        let name: String
        let path: String

        var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    }

    func summaryVault(in db: Database) throws -> SummaryVault {
        _ = try fetchVault(in: db)
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT id, name, path FROM vaults WHERE id = ?",
            arguments: [vaultID]
        ) else {
            throw MeetingAccessError.vaultNotFound
        }
        return SummaryVault(id: row["id"], name: row["name"], path: row["path"])
    }

    // MARK: - Prevalidation

    func makeSummaryUpdatePlan(
        meetingID: UUID,
        expectedDocumentVersion: String,
        document: SummaryDocument,
        vaultURL: URL,
        in db: Database
    ) throws -> SummaryUpdatePlan {
        guard try Bool.fetchOne(
            db,
            sql: "SELECT 1 FROM meetings WHERE id = ? AND vaultId = ?",
            arguments: [meetingID, vaultID]
        ) != nil else {
            throw MeetingAccessError.meetingNotFound
        }

        guard let summaryRow = try Row.fetchOne(
            db,
            sql: "SELECT title, document, createdAt FROM summaries WHERE meetingId = ?",
            arguments: [meetingID]
        ) else {
            throw MeetingAccessError.summaryNotFound
        }

        let existingDocument: String = summaryRow["document"]
        guard Self.summaryDocumentVersion(existingDocument) == expectedDocumentVersion else {
            throw MeetingAccessError.summaryVersionConflict
        }

        try validate(document)
        let storedDocument = try document.databaseJSONString()
        guard storedDocument.utf8.count <= SummaryWriteLimits.documentBytes else {
            throw MeetingAccessError.invalidSummaryUpdate(
                "The stored summary document must be at most \(SummaryWriteLimits.documentBytes) bytes."
            )
        }
        try validateScreenshotReferences(document, meetingID: meetingID, in: db)

        let existingTitle: String = summaryRow["title"]
        let meetingName = SummaryGeneratedMetadata.normalizedTitle(document.title)
        let meetingDescription = SummaryGeneratedMetadata.normalizedDescription(document.description)
        let staleExports = try self.staleExports(meetingID: meetingID, in: db)

        guard storedDocument != existingDocument else {
            return .unchanged(SummaryMutationResult(
                meetingID: meetingID,
                documentVersion: expectedDocumentVersion,
                title: existingTitle,
                description: meetingDescription ?? "",
                changed: false,
                vaultExport: .unchanged,
                staleExports: staleExports
            ))
        }

        let createdAt: Date = summaryRow["createdAt"]
        let vaultFile = try makeVaultFileWrite(
            meetingID: meetingID,
            document: document,
            createdAt: createdAt,
            vaultURL: vaultURL,
            in: db
        )

        return .apply(SummaryUpdate(
            meetingID: meetingID,
            storedDocument: storedDocument,
            summaryTitle: meetingName ?? existingTitle,
            meetingName: meetingName,
            meetingDescription: meetingDescription,
            tags: document.tags.filter { !$0.isEmpty },
            vaultFile: vaultFile.write,
            result: SummaryMutationResult(
                meetingID: meetingID,
                documentVersion: Self.summaryDocumentVersion(storedDocument),
                title: meetingName ?? existingTitle,
                description: meetingDescription ?? "",
                changed: true,
                vaultExport: vaultFile.outcome,
                staleExports: staleExports
            )
        ))
    }

    private func validate(_ document: SummaryDocument) throws {
        guard document.schemaVersion == 3 else {
            throw MeetingAccessError.invalidSummaryUpdate("schema_version must be 3.")
        }
        guard document.sections.count <= SummaryWriteLimits.sections else {
            throw MeetingAccessError.invalidSummaryUpdate(
                "The summary must have at most \(SummaryWriteLimits.sections) sections."
            )
        }

        var sectionIDs: Set<UUID> = []
        var blockIDs: Set<UUID> = []
        for section in document.sections {
            guard sectionIDs.insert(section.id).inserted else {
                throw MeetingAccessError.invalidSummaryUpdate("Section ids must be unique within the summary.")
            }
            guard section.blocks.count <= SummaryWriteLimits.blocksPerSection else {
                throw MeetingAccessError.invalidSummaryUpdate(
                    "Each section must have at most \(SummaryWriteLimits.blocksPerSection) blocks."
                )
            }
            for block in section.blocks where !blockIDs.insert(block.id).inserted {
                throw MeetingAccessError.invalidSummaryUpdate("Block ids must be unique within the summary.")
            }
        }
    }

    private func validateScreenshotReferences(
        _ document: SummaryDocument,
        meetingID: UUID,
        in db: Database
    ) throws {
        let referenced = document.referencedScreenshotIds
        guard !referenced.isEmpty else { return }
        guard try referenced.isSubset(of: meetingScreenshotIDs(meetingID: meetingID, in: db)) else {
            throw MeetingAccessError.summaryScreenshotNotFound
        }
    }

    private func meetingScreenshotIDs(meetingID: UUID, in db: Database) throws -> Set<UUID> {
        let ids = try UUID.fetchAll(
            db,
            sql: """
            SELECT screenshots.id
            FROM screenshots
            JOIN meetings ON meetings.id = screenshots.meetingId
            WHERE screenshots.meetingId = ? AND meetings.vaultId = ?
            """,
            arguments: [meetingID, vaultID]
        )
        return Set(ids)
    }

    private func staleExports(meetingID: UUID, in db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: "SELECT type FROM summary_exports WHERE meetingId = ? AND type <> 'vault' ORDER BY type",
            arguments: [meetingID]
        )
    }

    // MARK: - Vault markdown

    private func makeVaultFileWrite(
        meetingID: UUID,
        document: SummaryDocument,
        createdAt: Date,
        vaultURL: URL,
        in db: Database
    ) throws -> (write: VaultFileWrite?, outcome: SummaryMutationResult.VaultExportOutcome) {
        guard let storedURL = try String.fetchOne(
            db,
            sql: "SELECT url FROM summary_exports WHERE meetingId = ? AND type = 'vault'",
            arguments: [meetingID]
        ), let relativePath = vaultRelativeSummaryPath(storedURL) else {
            return (nil, .notExported)
        }

        guard let fileURL = VaultSummaryFileLocator.findSummaryFile(
            storedRelativePath: relativePath,
            vaultURL: vaultURL
        ) else {
            return (nil, .fileMissing)
        }
        let reachable = try isInsideVault(fileURL, vaultURL: vaultURL) && !containsSymbolicLink(fileURL, vaultURL: vaultURL)
        guard reachable else {
            return (nil, .fileMissing)
        }

        let screenshotFilenames = try screenshotFilenames(
            for: document.referencedScreenshotIds,
            meetingID: meetingID,
            in: db
        )
        let rendered = ObsidianMarkdownSummaryRenderer.render(
            document: document,
            context: SummaryMarkdownRenderContext(
                meetingId: meetingID,
                createdAt: createdAt,
                screenshotFilenames: screenshotFilenames
            )
        )

        let write = VaultFileWrite(
            fileURL: fileURL,
            relativePath: relativePath,
            markdown: rendered.markdown,
            previousContents: try? Data(contentsOf: fileURL)
        )
        return (write, .updated)
    }

    /// Vault へ書き出したスクリーンショットのファイル名。アプリの書き出し規則と一致させる。
    private func screenshotFilenames(
        for screenshotIDs: Set<UUID>,
        meetingID: UUID,
        in db: Database
    ) throws -> [UUID: String] {
        guard !screenshotIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: screenshotIDs.count).joined(separator: ", ")
        var arguments: StatementArguments = [meetingID, vaultID]
        arguments += StatementArguments(Array(screenshotIDs))
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT screenshots.id, screenshots.mimeType, screenshots.imageData
            FROM screenshots
            JOIN meetings ON meetings.id = screenshots.meetingId
            WHERE screenshots.meetingId = ? AND meetings.vaultId = ?
              AND screenshots.id IN (\(placeholders))
            """,
            arguments: arguments
        )

        var filenames: [UUID: String] = [:]
        for row in rows {
            let id: UUID = row["id"]
            let mimeType: String = row["mimeType"]
            if let filename = SummaryScreenshotFilename.filename(id: id, mimeType: mimeType) {
                filenames[id] = filename
                continue
            }
            let data: Data = row["imageData"] ?? Data()
            filenames[id] = SummaryScreenshotFilename.filename(id: id, mimeType: mimeType, imageData: data)
        }
        return filenames
    }

    private func containsSymbolicLink(_ fileURL: URL, vaultURL: URL) throws -> Bool {
        let root = vaultURL.standardizedFileURL
        var current = root
        for component in fileURL.standardizedFileURL.pathComponents.dropFirst(root.pathComponents.count) {
            current.append(path: component)
            if try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                return true
            }
        }
        return false
    }

    /// ファイルを先に書き、データベース更新が失敗したら元の内容へ戻す。
    private func writingVaultFile<T>(
        _ update: SummaryUpdate,
        operation: () throws -> T
    ) throws -> T {
        guard let file = update.vaultFile else { return try operation() }

        try Data(file.markdown.utf8).write(to: file.fileURL, options: .atomic)
        do {
            return try operation()
        } catch {
            guard let previousContents = file.previousContents else { throw error }
            do {
                try previousContents.write(to: file.fileURL, options: .atomic)
            } catch {
                throw MeetingAccessError.workspaceRollbackFailed
            }
            throw error
        }
    }

    // MARK: - Database

    func commitSummaryUpdate(_ update: SummaryUpdate, in db: Database) throws {
        let now = Date()
        try db.execute(
            sql: "UPDATE summaries SET title = ?, document = ? WHERE meetingId = ?",
            arguments: [update.summaryTitle, update.storedDocument, update.meetingID]
        )
        guard db.changesCount == 1 else {
            throw MeetingAccessError.summaryNotFound
        }

        var assignments = ["updatedAt = ?"]
        var arguments: StatementArguments = [now]
        if let meetingName = update.meetingName {
            assignments.append("name = ?")
            arguments += [meetingName]
        }
        if let meetingDescription = update.meetingDescription {
            assignments.append("description = ?")
            arguments += [meetingDescription]
        }
        arguments += [update.meetingID, vaultID]
        try db.execute(
            sql: "UPDATE meetings SET \(assignments.joined(separator: ", ")) WHERE id = ? AND vaultId = ?",
            arguments: arguments
        )

        try upsertTags(update.tags, meetingID: update.meetingID, now: now, in: db)

        if let file = update.vaultFile {
            try db.execute(
                sql: "UPDATE summary_exports SET url = ?, updatedAt = ? WHERE meetingId = ? AND type = 'vault'",
                arguments: [vaultSummaryURL(file.relativePath), now, update.meetingID]
            )
        }
    }

    /// アプリの生成経路と同じく追加のみ。既存タグは外さない。
    private func upsertTags(_ tags: [String], meetingID: UUID, now: Date, in db: Database) throws {
        for name in tags {
            let tagID: Int64
            if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE name = ?", arguments: [name]) {
                tagID = existing
            } else {
                try db.execute(
                    sql: "INSERT INTO tags (name, colorHex, createdAt) VALUES (?, ?, ?)",
                    arguments: [name, SummaryWriteLimits.generatedTagColorHex, now]
                )
                tagID = db.lastInsertedRowID
            }
            try db.execute(
                sql: "INSERT OR IGNORE INTO meeting_tags (meetingId, tagId) VALUES (?, ?)",
                arguments: [meetingID, tagID]
            )
        }
    }
}
