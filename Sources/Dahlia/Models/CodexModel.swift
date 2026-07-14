import Foundation

struct CodexModel: Codable, Hashable, Identifiable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let hidden: Bool
    let isDefault: Bool
    let supportedReasoningEfforts: [CodexReasoningEffortOption]
    let defaultReasoningEffort: String
    let inputModalities: [String]?

    var supportsImages: Bool {
        inputModalities?.contains("image") ?? false
    }
}
