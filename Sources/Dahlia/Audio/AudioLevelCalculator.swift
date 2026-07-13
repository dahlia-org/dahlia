@preconcurrency import AVFoundation

enum AudioLevelCalculator {
    static func normalizedLevel(in buffer: AVAudioPCMBuffer) -> Double {
        normalizedLevels(in: buffer).max() ?? 0
    }

    static func normalizedLevels(in buffer: AVAudioPCMBuffer) -> [Double] {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0,
              buffer.format.channelCount > 0 else { return [] }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        return (0 ..< channelCount).map { channel in
            var sumOfSquares = 0.0
            let samples = buffer.format.isInterleaved ? channels[0] : channels[channel]

            for frame in 0 ..< frameCount {
                let sampleIndex = buffer.format.isInterleaved ? (frame * channelCount) + channel : frame
                let sample = Double(samples[sampleIndex])
                sumOfSquares += sample * sample
            }

            let rootMeanSquare = sqrt(sumOfSquares / Double(frameCount))
            guard rootMeanSquare > 0 else { return 0 }
            let decibels = 20 * log10(rootMeanSquare)
            return min(1, max(0, (decibels + 60) / 60))
        }
    }
}
