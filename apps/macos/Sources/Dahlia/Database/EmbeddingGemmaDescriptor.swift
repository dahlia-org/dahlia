import CryptoKit
import Foundation

/// Frozen constants required by the released v37 migration.
enum EmbeddingGemmaDescriptor {
    static let repository = "mlx-community/embeddinggemma-300m-4bit"
    static let revision = "5d9ef074df3957afc5c77127f208fddbc3c54187"
    static let dimensions = 256
    static let maximumTokens = 2048
    static let queryPrompt = "task: search result | query: "
    static let documentPrompt = "title: %@ | text: %@"
    static let modelIdentifier = "\(repository)@\(revision)"
    static let configurationHash = sha256(
        "\(modelIdentifier)|\(dimensions)|\(maximumTokens)|\(queryPrompt)|\(documentPrompt)|meeting-v5|project-v3"
    )
    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
