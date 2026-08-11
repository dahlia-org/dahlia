import Foundation
import GRDB

/// 保管庫を表す GRDB レコード。path は保管庫ディレクトリの絶対パスに対応する。
struct VaultRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "vaults"

    var id: UUID
    var path: String
    var name: String
    var createdAt: Date
    var lastOpenedAt: Date

    /// 保管庫ディレクトリの URL。
    var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}
