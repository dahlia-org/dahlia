import Foundation

enum SummaryStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case concise, standard, detailed, eventSummary, eventTimeline

    var id: Self { self }
    var detailLevel: SummaryDetailLevel {
        switch self {
        case .concise: .concise
        case .standard: .standard
        case .detailed: .detailed
        case .eventSummary: .eventSession
        case .eventTimeline: .max
        }
    }

    var displayName: String { detailLevel.displayName }

    var description: String {
        switch self {
        case .concise: L10n.summaryStyleConciseDescription
        case .standard: L10n.summaryStyleStandardDescription
        case .detailed: L10n.summaryStyleDetailedDescription
        case .eventSummary: L10n.summaryStyleEventDescription
        case .eventTimeline: L10n.summaryStyleTimelineDescription
        }
    }

    init(detailLevel: SummaryDetailLevel) {
        switch detailLevel {
        case .concise: self = .concise
        case .standard: self = .standard
        case .detailed: self = .detailed
        case .eventSession: self = .eventSummary
        case .max: self = .eventTimeline
        }
    }
}
