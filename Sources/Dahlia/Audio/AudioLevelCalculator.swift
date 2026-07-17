@preconcurrency import AVFoundation

enum AudioLevelCalculator {
    static func normalizedLevel(in buffer: AVAudioPCMBuffer) -> Double {
        normalizedLevels(in: buffer).max() ?? 0
    }

    static func normalizedLevels(in buffer: AVAudioPCMBuffer) -> [Double] {
        guard buffer.frameLength > 0,
              buffer.format.channelCount > 0 else { return [] }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = buffer.floatChannelData else { return [] }
            return calculateLevels(frameCount: frameCount, channelCount: channelCount) { channel, frame in
                let samples = buffer.format.isInterleaved ? channels[0] : channels[channel]
                let index = buffer.format.isInterleaved ? (frame * channelCount) + channel : frame
                return Double(samples[index])
            }
        case .pcmFormatInt16:
            guard let channels = buffer.int16ChannelData else { return [] }
            return calculateLevels(frameCount: frameCount, channelCount: channelCount) { channel, frame in
                let samples = buffer.format.isInterleaved ? channels[0] : channels[channel]
                let index = buffer.format.isInterleaved ? (frame * channelCount) + channel : frame
                return Double(samples[index]) / Double(Int16.max)
            }
        default:
            return []
        }
    }

    private static func calculateLevels(
        frameCount: Int,
        channelCount: Int,
        sample: (_ channel: Int, _ frame: Int) -> Double
    ) -> [Double] {
        (0 ..< channelCount).map { channel in
            var sumOfSquares = 0.0
            for frame in 0 ..< frameCount {
                let value = sample(channel, frame)
                sumOfSquares += value * value
            }

            let rootMeanSquare = sqrt(sumOfSquares / Double(frameCount))
            guard rootMeanSquare > 0 else { return 0 }
            let decibels = 20 * log10(rootMeanSquare)
            return min(1, max(0, (decibels + 60) / 60))
        }
    }
}
