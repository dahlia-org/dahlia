@preconcurrency import AVFoundation
import CoreMedia
import Speech

/// macOS 26 向けの `AnalyzerInputConverting` 実装。
/// 公式の `AnalyzerInputConverter` が利用可能になるまでの adapter。
final class AVAudioAnalyzerInputConverter: AnalyzerInputConverting {
    private let analyzerFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(sourceFormat: AVAudioFormat, analyzerFormat: AVAudioFormat) throws {
        guard let converter = AudioConverter.makeConverter(from: sourceFormat, to: analyzerFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        self.analyzerFormat = analyzerFormat
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer, at startTime: CMTime) throws -> [AnalyzerInput] {
        guard let converted = AudioConverter.convert(buffer, to: analyzerFormat, using: converter) else {
            throw AudioCaptureError.converterCreationFailed
        }
        return [AnalyzerInput(buffer: converted, bufferStartTime: startTime)]
    }

    func finish() throws -> [AnalyzerInput] {
        []
    }
}
