import GRDB

enum SummaryExportType: String, Codable, DatabaseValueConvertible {
    case vault
    case googleDocs = "google_docs"
}
