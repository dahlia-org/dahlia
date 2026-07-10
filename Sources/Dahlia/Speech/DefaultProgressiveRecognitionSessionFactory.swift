@preconcurrency import AVFoundation
import Foundation

/// Apple Speechのprogressive recognizerを生成するdefault factory。
/// converter factoryを差し替えることで、公式AnalyzerInputConverterへ移行できる。
struct DefaultProgressiveRecognitionSessionFactory: ProgressiveRecognitionSessionFactory {
    private let inputConverterFactory: AnalyzerInputConverterFactory

    init(inputConverterFactory: @escaping AnalyzerInputConverterFactory = { sourceFormat, analyzerFormat in
        try AVAudioAnalyzerInputConverter(
            sourceFormat: sourceFormat,
            analyzerFormat: analyzerFormat
        )
    }) {
        self.inputConverterFactory = inputConverterFactory
    }

    func prepareModel(locale: Locale) async throws {
        try await SpeechTranscriberService.ensureModelInstalled(locale: locale)
    }

    func prepareSession(
        locale: Locale,
        source: RecordingAudioSource,
        sourceFormat: AVAudioFormat?,
        bufferingMode: AudioBufferBridge.BufferingMode,
        translateSegment: ProgressiveSegmentTranslationHandler?
    ) async throws -> PreparedProgressiveRecognitionSession {
        let service = SpeechTranscriberService(
            locale: locale,
            speakerLabel: source.speakerLabel,
            translateSegment: translateSegment
        )
        try await service.prepare()
        guard let analyzerFormat = await service.targetAudioFormat() else {
            throw AudioCaptureError.converterCreationFailed
        }

        let captureFormat = sourceFormat ?? analyzerFormat
        let inputConverter: (any AnalyzerInputConverting)? = if captureFormat != analyzerFormat {
            try inputConverterFactory(captureFormat, analyzerFormat)
        } else {
            nil
        }
        let bridge = try AudioBufferBridge(
            sourceFormat: captureFormat,
            analyzerFormat: analyzerFormat,
            inputConverter: inputConverter,
            bufferingMode: bufferingMode
        )
        return PreparedProgressiveRecognitionSession(
            analyzerFormat: analyzerFormat,
            session: DefaultProgressiveRecognitionSession(service: service, bridge: bridge)
        )
    }
}
