import Foundation
import GRDB

/// CAFがアプリ管理領域とWorkspaceのどちらにあるかを表す。
enum RecordingAudioStorageLocation: String, Codable, CaseIterable, DatabaseValueConvertible {
    case managed
    case workspace = "vault"
}
