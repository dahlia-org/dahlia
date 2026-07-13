@preconcurrency import AVFoundation
@testable import Dahlia

final class FakeVoiceProcessingInput: VoiceProcessingInputConfiguring {
    private(set) var enableRequests: [Bool] = []
    private(set) var duckingConfigurationSetCount = 0
    var voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
        enableAdvancedDucking: false,
        duckingLevel: .default
    ) {
        didSet {
            duckingConfigurationSetCount += 1
        }
    }

    func setVoiceProcessingEnabled(_ enabled: Bool) throws {
        enableRequests.append(enabled)
    }
}
