import Foundation
import GRDB

enum ProjectType: String, CaseIterable, Codable, DatabaseValueConvertible, Sendable {
    case customer
    case `internal`
    case personal
    case undefined
}
