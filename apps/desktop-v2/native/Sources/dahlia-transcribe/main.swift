// dahlia-transcribe: transcribes one headerless 16-bit mono PCM file on the Mac with Apple Speech.
//
//   dahlia-transcribe locales
//   dahlia-transcribe transcribe --locale ja-JP --sample-rate 16000 <file.pcm>
//
// stdout is JSON Lines: {"type":"asset","fraction":…}, {"type":"progress","processed_ms":…},
// {"type":"segment","start_ms":…,"end_ms":…,"text":…}, then {"type":"done"} or {"type":"error","code":…}.
// Nothing derived from the audio goes to stderr.
import AVFoundation
import Foundation
import Speech

enum Failure: String, Error {
    case usage, unsupported_locale, assets_unavailable, invalid_audio, failed
}

func emit(_ object: [String: any Sendable]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func milliseconds(_ time: CMTime) -> Int {
    time.isNumeric ? Int((time.seconds * 1000).rounded()) : 0
}

/// Reads the PCM file a buffer at a time on demand, so a long recording never sits in memory.
struct PCMInputSequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let reader: PCMReader
    func makeAsyncIterator() -> Iterator { Iterator(reader: reader) }
    struct Iterator: AsyncIteratorProtocol {
        let reader: PCMReader
        mutating func next() async throws -> AnalyzerInput? { try await reader.next() }
    }
}

actor PCMReader {
    private static let framesPerRead = 16000 * 4
    private let handle: FileHandle
    private let sourceFormat: AVAudioFormat
    private let analyzerFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private var sourceFrames: Int64 = 0
    private var analyzerFrames: Int64 = 0

    init(url: URL, sourceFormat: AVAudioFormat, analyzerFormat: AVAudioFormat) throws {
        handle = try FileHandle(forReadingFrom: url)
        self.sourceFormat = sourceFormat
        self.analyzerFormat = analyzerFormat
        if sourceFormat == analyzerFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat) else { throw Failure.invalid_audio }
            self.converter = converter
        }
    }

    func next() throws -> AnalyzerInput? {
        try Task.checkCancellation()
        // A crash during recording can leave half a sample at the end; whole samples only.
        guard let data = try handle.read(upToCount: Self.framesPerRead * 2), data.count >= 2 else { return nil }
        let frames = AVAudioFrameCount(data.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames),
              let channel = buffer.int16ChannelData?[0] else { throw Failure.invalid_audio }
        buffer.frameLength = frames
        data.withUnsafeBytes { bytes in
            _ = bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: channel, count: Int(frames) * 2))
        }
        sourceFrames += Int64(frames)
        emit(["type": "progress", "processed_ms": Int(sourceFrames * 1000 / Int64(sourceFormat.sampleRate))])
        let output = try convert(buffer)
        let start = CMTime(value: analyzerFrames, timescale: CMTimeScale(analyzerFormat.sampleRate.rounded()))
        analyzerFrames += Int64(output.frameLength)
        return AnalyzerInput(buffer: output, bufferStartTime: start)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter else { return buffer }
        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { throw Failure.invalid_audio }
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { throw Failure.invalid_audio }
        return output
    }
}

func installAssets(for transcriber: SpeechTranscriber) async throws {
    guard await AssetInventory.status(forModules: [transcriber]) < .installed else { return }
    do {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let reporter = Task {
            while !Task.isCancelled {
                emit(["type": "asset", "fraction": request.progress.fractionCompleted])
                try await Task.sleep(for: .seconds(1))
            }
        }
        defer { reporter.cancel() }
        try await request.downloadAndInstall()
    } catch {
        throw Failure.assets_unavailable
    }
}

func transcribe(localeIdentifier: String, sampleRate: Double, url: URL) async throws {
    guard SpeechTranscriber.isAvailable,
          let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier))
    else { throw Failure.unsupported_locale }
    // The preset Dahlia for macOS uses for recorded audio: final results with their audio time ranges.
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    try await installAssets(for: transcriber)

    guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false),
          let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: sourceFormat)
    else { throw Failure.invalid_audio }
    let reader = try PCMReader(url: url, sourceFormat: sourceFormat, analyzerFormat: analyzerFormat)
    // Below the next recording: the analysis can wait, capture cannot.
    let analyzer = SpeechAnalyzer(modules: [transcriber], options: SpeechAnalyzer.Options(priority: .utility, modelRetention: .whileInUse))
    try await analyzer.prepareToAnalyze(in: analyzerFormat)

    let results = Task {
        for try await result in transcriber.results where result.isFinal {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            emit(["type": "segment", "start_ms": milliseconds(result.range.start), "end_ms": milliseconds(result.range.end), "text": text])
        }
    }
    do {
        if let last = try await analyzer.analyzeSequence(PCMInputSequence(reader: reader)) {
            // Closing the input alone does not end the result stream.
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        try await results.value
    } catch {
        results.cancel()
        await analyzer.cancelAndFinishNow()
        throw error
    }
}

func run(_ arguments: [String]) async throws {
    switch arguments.first {
    case "locales":
        let locales = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted()
        emit(["type": "locales", "locales": locales])
    case "transcribe":
        var options: [String: String] = [:]
        var paths: [String] = []
        var rest = arguments.dropFirst()[...]
        while let argument = rest.popFirst() {
            if argument.hasPrefix("--") {
                guard let value = rest.popFirst() else { throw Failure.usage }
                options[argument] = value
            } else {
                paths.append(argument)
            }
        }
        guard let locale = options["--locale"], let rate = Double(options["--sample-rate"] ?? "16000"), rate > 0,
              paths.count == 1, let path = paths.first else { throw Failure.usage }
        let url = URL(filePath: path)
        guard FileManager.default.isReadableFile(atPath: url.path),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw Failure.invalid_audio }
        // Less than one sample has no speech; the analyzer would only report a cancellation.
        if size >= 2 {
            try await transcribe(localeIdentifier: locale, sampleRate: rate, url: url)
        }
    default:
        throw Failure.usage
    }
    emit(["type": "done"])
}

do {
    try await run(Array(CommandLine.arguments.dropFirst()))
    exit(0)
} catch let failure as Failure {
    emit(["type": "error", "code": failure.rawValue])
    exit(failure == .usage ? 64 : 1)
} catch {
    emit(["type": "error", "code": Failure.failed.rawValue])
    exit(1)
}
