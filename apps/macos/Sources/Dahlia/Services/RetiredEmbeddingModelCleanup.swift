import Foundation

enum RetiredEmbeddingModelCleanup {
    static func remove(from applicationSupportDirectory: URL) throws {
        let directory = applicationSupportDirectory.appending(path: "Models/EmbeddingGemma")
        do {
            try FileManager.default.removeItem(at: directory)
        } catch CocoaError.fileNoSuchFile {
            // Already removed, or this profile never installed the model.
        }
    }
}
