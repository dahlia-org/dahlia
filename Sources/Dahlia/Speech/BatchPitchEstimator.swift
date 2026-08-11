import Accelerate
import Foundation

enum BatchPitchEstimator {
    private static let lowPassCutoffHertz = 800.0
    private static let lowPassStageCount = 4
    private static let minimumFilteredPowerRatio = 0.01

    static func estimate(in samples: [Float], sampleRate: Double) -> Double? {
        guard sampleRate > 0, !samples.isEmpty else { return nil }
        let inputMeanSquare = meanSquare(of: samples)
        guard inputMeanSquare > 0 else { return nil }
        let filtered = lowPass(samples, sampleRate: sampleRate)
        guard meanSquare(of: filtered) >= inputMeanSquare * minimumFilteredPowerRatio else {
            return nil
        }
        let downsampleFactor = sampleRate >= 12000 ? 2 : 1
        let downsampled = stride(from: 0, to: filtered.count, by: downsampleFactor).map {
            filtered[$0]
        }
        guard downsampled.count >= 3 else { return nil }
        let analysisSampleRate = sampleRate / Double(downsampleFactor)
        let mean = downsampled.reduce(0, +) / Float(downsampled.count)
        let centered = downsampled.map { $0 - mean }
        let minimumLag = max(1, Int(floor(
            analysisSampleRate / BatchTranscriptAudioFeatureAnalyzer.maximumPitchHertz
        )))
        let maximumLag = min(
            centered.count - 2,
            Int(ceil(analysisSampleRate / BatchTranscriptAudioFeatureAnalyzer.minimumPitchHertz))
        )
        guard minimumLag < maximumLag else { return nil }

        let correlations = normalizedCorrelations(
            in: centered,
            minimumLag: minimumLag,
            maximumLag: maximumLag
        )
        guard let strongestCorrelation = correlations.max(),
              Double(strongestCorrelation) >= BatchTranscriptAudioFeatureAnalyzer.minimumPitchCorrelation,
              let lag = refinedLag(
                  correlations: correlations,
                  minimumLag: minimumLag,
                  strongestCorrelation: strongestCorrelation
              ) else {
            return nil
        }
        let pitch = analysisSampleRate / lag
        guard pitch >= BatchTranscriptAudioFeatureAnalyzer.minimumPitchHertz,
              pitch <= BatchTranscriptAudioFeatureAnalyzer.maximumPitchHertz else { return nil }
        return pitch
    }

    private static func lowPass(_ samples: [Float], sampleRate: Double) -> [Float] {
        let alpha = Float(1 - exp(-2 * Double.pi * lowPassCutoffHertz / sampleRate))
        var filtered = samples
        for _ in 0 ..< lowPassStageCount {
            var previous: Float = 0
            for index in filtered.indices {
                previous += alpha * (filtered[index] - previous)
                filtered[index] = previous
            }
        }
        return filtered
    }

    private static func meanSquare(of samples: [Float]) -> Double {
        samples.reduce(0.0) {
            $0 + (Double($1) * Double($1))
        } / Double(samples.count)
    }

    private static func normalizedCorrelations(
        in centered: [Float],
        minimumLag: Int,
        maximumLag: Int
    ) -> [Float] {
        var prefixEnergy = Array(repeating: Float.zero, count: centered.count + 1)
        for index in centered.indices {
            prefixEnergy[index + 1] = prefixEnergy[index] + (centered[index] * centered[index])
        }
        var correlations = Array(repeating: Float.zero, count: maximumLag - minimumLag + 1)
        centered.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            for lag in minimumLag ... maximumLag {
                let count = centered.count - lag
                var dotProduct: Float = 0
                vDSP_dotpr(
                    baseAddress,
                    1,
                    baseAddress.advanced(by: lag),
                    1,
                    &dotProduct,
                    vDSP_Length(count)
                )
                let firstEnergy = prefixEnergy[count]
                let secondEnergy = prefixEnergy[centered.count] - prefixEnergy[lag]
                let denominator = sqrt(firstEnergy * secondEnergy)
                if denominator > 0 {
                    correlations[lag - minimumLag] = dotProduct / denominator
                }
            }
        }
        return correlations
    }

    private static func refinedLag(
        correlations: [Float],
        minimumLag: Int,
        strongestCorrelation: Float
    ) -> Double? {
        let acceptableCorrelation = max(
            Float(BatchTranscriptAudioFeatureAnalyzer.minimumPitchCorrelation),
            strongestCorrelation - 0.02
        )
        let peakOffset = correlations.indices.first { index in
            correlations[index] >= acceptableCorrelation
                && (index == correlations.startIndex || correlations[index] >= correlations[index - 1])
                && (index == correlations.index(before: correlations.endIndex)
                    || correlations[index] >= correlations[index + 1])
        } ?? correlations.indices.max(by: { correlations[$0] < correlations[$1] })
        guard let peakOffset else { return nil }

        var lag = Double(peakOffset + minimumLag)
        if peakOffset > correlations.startIndex,
           peakOffset < correlations.index(before: correlations.endIndex) {
            let previous = Double(correlations[peakOffset - 1])
            let current = Double(correlations[peakOffset])
            let next = Double(correlations[peakOffset + 1])
            let denominator = previous - (2 * current) + next
            if abs(denominator) > .ulpOfOne {
                lag += 0.5 * (previous - next) / denominator
            }
        }
        guard lag > 0 else { return nil }
        return lag
    }
}
