import Foundation

struct MeetingMetricsFinding: Sendable, Equatable {
    enum Kind: String, CaseIterable, Sendable {
        case micPaceProvisionalFast
        case highMicShare
        case highSourceOverlap
    }

    enum Evidence: Sendable, Equatable {
        case charactersPerMinute(Double)
        case share(Double)
        case overlap(seconds: Double, share: Double)
    }

    let kind: Kind
    let evidence: Evidence
}

struct MeetingMetricsInsightSet: Sendable, Equatable {
    enum Availability: String, Sendable {
        case ok
        case insufficientTranscript
        case insufficientCoverage
    }

    let availability: Availability
    let findings: [MeetingMetricsFinding]
}
