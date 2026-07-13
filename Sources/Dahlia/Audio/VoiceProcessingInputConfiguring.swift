@preconcurrency import AVFoundation

protocol VoiceProcessingInputConfiguring: AnyObject {
    func setVoiceProcessingEnabled(_ enabled: Bool) throws

    var voiceProcessingOtherAudioDuckingConfiguration: AVAudioVoiceProcessingOtherAudioDuckingConfiguration { get set }
}

extension AVAudioInputNode: VoiceProcessingInputConfiguring {}
