@preconcurrency import AVFoundation

/// AVAudioConverter を使用して入力バッファをターゲットフォーマットに変換する。
/// AudioCaptureManager と SystemAudioCaptureManager の共通処理を集約。
enum AudioConverter {
    static func convert(
        _ inputBuffer: AVAudioPCMBuffer,
        to targetFormat: AVAudioFormat,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio))
        guard outputFrameCount > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else { return nil }

        var error: NSError?
        nonisolated(unsafe) var inputConsumed = false

        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputConsumed = true
            return inputBuffer
        }

        guard status != .error, error == nil else { return nil }
        guard outputBuffer.frameLength > 0 else { return nil }

        return outputBuffer
    }
}
