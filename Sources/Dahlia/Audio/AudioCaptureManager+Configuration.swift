@preconcurrency import AVFoundation
import CoreAudio

extension AudioCaptureManager {
    static func voiceProcessingAttemptOrder(prefersVoiceProcessing: Bool) -> [Bool] {
        prefersVoiceProcessing ? [true, false] : [false]
    }

    static func captureSourceFormat(
        hardwareFormat: AVAudioFormat,
        voiceProcessingFormat: AVAudioFormat?,
        enablesVoiceProcessing: Bool
    ) -> AVAudioFormat {
        if enablesVoiceProcessing, let voiceProcessingFormat {
            voiceProcessingFormat
        } else {
            hardwareFormat
        }
    }

    static func voiceProcessingFormatsMatch(_ inputFormat: AVAudioFormat, _ outputFormat: AVAudioFormat) -> Bool {
        inputFormat.sampleRate == outputFormat.sampleRate
            && inputFormat.channelCount == outputFormat.channelCount
    }
}
