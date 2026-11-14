import DahliaRuntimeSupport
import Foundation

struct SummaryVersion: Decodable, Identifiable, Sendable {
    var id: Int { version }
    let version: Int
    let title: String
    let savedAt: Date
    let metadata: SummaryMetadata?
    var document: String?
}
