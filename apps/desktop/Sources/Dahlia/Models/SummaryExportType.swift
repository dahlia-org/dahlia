import GRDB

enum SummaryExportType: String, Codable, DatabaseValueConvertible {
    case vault
    case googleDocs = "google_docs"
    /// Retain decoding of existing export history after Server Artifact retirement.
    case dahliaArtifact = "dahlia_artifact"
}
