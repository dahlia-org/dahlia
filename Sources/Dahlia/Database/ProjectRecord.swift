import Foundation
import GRDB

/// プロジェクトを表す GRDB レコード。name は保管庫内の相対パス（フォルダ名）に対応する。
struct ProjectRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "projects"

    var id: UUID
    var vaultId: UUID
    var name: String
    var createdAt: Date
    var description = ""
    var missingOnDisk = false

    // MARK: - Shared DB Helpers

    /// 複数の name を INSERT OR IGNORE で一括挿入する（vaultId + name UNIQUE 制約を利用）。
    static func upsertAll(names: [String], vaultId: UUID, in db: Database) throws {
        let now = Date()
        for name in names {
            let record = ProjectRecord(
                id: .v7(),
                vaultId: vaultId,
                name: name,
                createdAt: now,
                description: ""
            )
            try record.insert(db, onConflict: .ignore)
        }
    }

    /// name が指定プレフィクスで始まるレコードを一括リネームする。
    static func renameByPrefix(oldPrefix: String, newPrefix: String, vaultId: UUID, in db: Database) throws {
        let records = try hierarchy(prefix: oldPrefix, vaultId: vaultId, in: db)
        for var record in records {
            record.name = newPrefix + record.name.dropFirst(oldPrefix.count)
            try record.update(db)
        }
    }

    /// name が指定プレフィクスに一致するレコード、または配下のレコードを一括削除する。
    @discardableResult
    static func deleteByPrefix(_ prefix: String, vaultId: UUID, in db: Database) throws -> Int {
        let ids = try hierarchy(prefix: prefix, vaultId: vaultId, in: db).map(\.id)
        guard !ids.isEmpty else { return 0 }
        return try Self.filter(ids.contains(Column("id"))).deleteAll(db)
    }

    /// 指定プレフィクスに一致するプロジェクトの missingOnDisk を更新する。
    static func setMissingByPrefix(_ prefix: String, missing: Bool, vaultId: UUID, in db: Database) throws {
        let ids = try hierarchy(prefix: prefix, vaultId: vaultId, in: db).map(\.id)
        guard !ids.isEmpty else { return }
        _ = try ProjectRecord
            .filter(ids.contains(Column("id")))
            .updateAll(db, Column("missingOnDisk").set(to: missing))
    }

    /// 指定パス自身と、その配下のプロジェクトを返す。
    static func hierarchy(prefix: String, vaultId: UUID, in db: Database) throws -> [ProjectRecord] {
        try ProjectRecord
            .filter(Column("vaultId") == vaultId)
            .fetchAll(db)
            .filter { belongsToHierarchy($0.name, prefix: prefix) }
            .sorted { $0.name.count < $1.name.count }
    }

    static func belongsToHierarchy(_ name: String, prefix: String) -> Bool {
        name == prefix || name.hasPrefix(prefix + "/")
    }

    /// パス文字列から中間パスを含む全パスを生成する。
    /// 例: "a/b/c" → ["a", "a/b", "a/b/c"]
    static func allIntermediatePaths(for name: String) -> [String] {
        let components = name.split(separator: "/")
        return (1 ... components.count).map { i in
            components[0 ..< i].joined(separator: "/")
        }
    }
}
