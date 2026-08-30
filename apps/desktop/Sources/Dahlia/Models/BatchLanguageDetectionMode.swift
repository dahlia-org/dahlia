import Foundation
import GRDB

enum BatchLanguageDetectionMode: String, Codable, DatabaseValueConvertible, Sendable {
    case manual
    case automatic
}
