@preconcurrency import AVFoundation
import CoreMedia
import Speech

typealias AnalyzerInputConverterFactory = @Sendable (
    _ sourceFormat: AVAudioFormat,
    _ analyzerFormat: AVAudioFormat
) throws -> any AnalyzerInputConverting

/// Capture 形式のバッファを SpeechAnalyzer 入力へ変換する境界。
///
/// macOS SDK で `AnalyzerInputConverter` が利用可能になった時は、
/// この protocol に適合する adapter と差し替える。
protocol AnalyzerInputConverting: AnyObject, Sendable {
    func convert(_ buffer: AVAudioPCMBuffer, at startTime: CMTime) throws -> [AnalyzerInput]
    func finish() throws -> [AnalyzerInput]
}
