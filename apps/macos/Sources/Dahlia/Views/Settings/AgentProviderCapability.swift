import Foundation

enum AgentProviderCapability: CaseIterable, Hashable {
    case models
    case mcp
    case calendar
    case storage

    var title: String {
        switch self {
        case .models: L10n.agentProviderModels
        case .mcp: L10n.mcp
        case .calendar: L10n.calendar
        case .storage: L10n.agentProviderStorage
        }
    }
}
