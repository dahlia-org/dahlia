import Foundation

/// A compact, best-effort summary of the audio associated with one transcript segment.
struct TranscriptAudioFeatures: Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let activeRmsDecibels: Double?
    let medianPitchHertz: Double?
    let voicedFrameRatio: Double
    let pitchSpreadHertz: Double?

    init(
        version: Int = currentVersion,
        activeRmsDecibels: Double?,
        medianPitchHertz: Double?,
        voicedFrameRatio: Double,
        pitchSpreadHertz: Double?
    ) {
        self.version = version
        self.activeRmsDecibels = activeRmsDecibels
        self.medianPitchHertz = medianPitchHertz
        self.voicedFrameRatio = voicedFrameRatio
        self.pitchSpreadHertz = pitchSpreadHertz
    }
}
