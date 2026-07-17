import Foundation
import GRDB

/// 録音セッションで使用する文字起こし方式。
enum TranscriptionMode: String, Codable, DatabaseValueConvertible {
    case realtime
    case batch

    nonisolated static let userDefaultsKey = "transcriptionMode"
    nonisolated static let defaultMode: TranscriptionMode = .batch
}
