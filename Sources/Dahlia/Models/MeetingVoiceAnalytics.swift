import Foundation

struct MeetingVoiceAnalytics: Equatable, Sendable {
    static let empty = Self(
        excitement: Excitement(samples: [], hotspots: [], sourcesUsingPitch: []),
        expressions: [],
        pitchEntrainment: nil,
        energyTrend: EnergyTrend(samples: [], slopePerMinute: [:], decliningSources: []),
        sourceStatuses: [
            SourceStatus(source: .microphone, availability: .unavailable),
            SourceStatus(source: .system, availability: .unavailable),
        ]
    )

    enum Availability: Equatable, Sendable {
        case unavailable
        case insufficientSamples
        case available
    }

    enum ExpressionLevel: Equatable, Sendable {
        case low
        case standard
        case high
    }

    enum HotspotDriver: Equatable, Sendable {
        case loudness
        case pitch
        case both
    }

    struct SourceStatus: Equatable, Identifiable, Sendable {
        let source: RecordingAudioSource
        let availability: Availability

        var id: RecordingAudioSource { source }
    }

    struct SourceSample: Equatable, Identifiable, Sendable {
        let source: RecordingAudioSource
        let start: TimeInterval
        let end: TimeInterval
        let value: Double
        let seriesIndex: Int

        var id: String {
            "\(source.rawValue):\(start.bitPattern):\(end.bitPattern)"
        }

        var seriesID: String {
            "\(source.rawValue):\(seriesIndex)"
        }

        var midpoint: TimeInterval {
            start + (end - start) / 2
        }
    }

    struct Hotspot: Equatable, Identifiable, Sendable {
        let source: RecordingAudioSource
        let start: TimeInterval
        let end: TimeInterval
        let coveredDuration: TimeInterval
        let peakScore: Double
        let driver: HotspotDriver

        var id: String {
            "\(source.rawValue):\(start.bitPattern):\(end.bitPattern)"
        }
    }

    struct Excitement: Equatable, Sendable {
        let samples: [SourceSample]
        let hotspots: [Hotspot]
        let sourcesUsingPitch: Set<RecordingAudioSource>
    }

    struct SourceExpression: Equatable, Identifiable, Sendable {
        let source: RecordingAudioSource
        let pitchVariationSemitones: Double?
        let pitchLevel: ExpressionLevel?
        let loudnessVariationDecibels: Double?
        let loudnessLevel: ExpressionLevel?

        var id: RecordingAudioSource { source }
    }

    struct PitchDistanceSample: Equatable, Identifiable, Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let distanceSemitones: Double
        let seriesIndex: Int

        var id: String {
            "\(start.bitPattern):\(end.bitPattern)"
        }

        var midpoint: TimeInterval {
            start + (end - start) / 2
        }

        var seriesID: String {
            "pitch-distance:\(seriesIndex)"
        }
    }

    struct PitchEntrainment: Equatable, Sendable {
        let distanceSamples: [PitchDistanceSample]
        let firstThirdMeanDistance: Double
        let lastThirdMeanDistance: Double
        let isConverging: Bool
    }

    struct EnergyTrend: Equatable, Sendable {
        let samples: [SourceSample]
        let slopePerMinute: [RecordingAudioSource: Double]
        let decliningSources: Set<RecordingAudioSource>
    }

    let excitement: Excitement
    let expressions: [SourceExpression]
    let pitchEntrainment: PitchEntrainment?
    let energyTrend: EnergyTrend
    let sourceStatuses: [SourceStatus]

    func status(for source: RecordingAudioSource) -> Availability {
        sourceStatuses.first(where: { $0.source == source })?.availability ?? .unavailable
    }

    var hasAvailableSource: Bool {
        sourceStatuses.contains { $0.availability == .available }
    }
}
