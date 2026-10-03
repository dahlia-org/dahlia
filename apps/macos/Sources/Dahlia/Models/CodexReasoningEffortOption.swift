import Foundation

struct CodexReasoningEffortOption: Codable, Hashable, Identifiable {
    nonisolated static let defaultValue = "medium"

    let reasoningEffort: String
    let description: String

    var id: String { reasoningEffort }

    var displayName: String {
        switch reasoningEffort {
        case "none": L10n.reasoningEffortNone
        case "minimal": L10n.reasoningEffortMinimal
        case "low": L10n.reasoningEffortLow
        case Self.defaultValue: L10n.reasoningEffortMedium
        case "high": L10n.reasoningEffortHigh
        case "xhigh": L10n.reasoningEffortExtraHigh
        case "max": L10n.reasoningEffortMax
        case "ultra": L10n.reasoningEffortUltra
        default: reasoningEffort
        }
    }
}
