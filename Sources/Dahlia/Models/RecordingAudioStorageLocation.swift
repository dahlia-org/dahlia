import Foundation
import GRDB

/// CAFがアプリ管理領域とVaultのどちらにあるかを表す。
enum RecordingAudioStorageLocation: String, Codable, CaseIterable, DatabaseValueConvertible {
    case managed
    case vault
}
