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

    static func voiceProcessingHardwareFormatsAreCompatible(
        _ inputFormat: AVAudioFormat,
        _ outputHardwareFormat: AVAudioFormat
    ) -> Bool {
        inputFormat.sampleRate == outputHardwareFormat.sampleRate
            && inputFormat.channelCount > 0
            && outputHardwareFormat.channelCount > 0
    }

    static func voiceProcessingOutputClientFormat(
        inputFormat: AVAudioFormat,
        outputHardwareFormat: AVAudioFormat
    ) -> AVAudioFormat? {
        guard voiceProcessingHardwareFormatsAreCompatible(inputFormat, outputHardwareFormat) else { return nil }
        return inputFormat
    }
}
