@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

struct BatchSpeechAnalyzerInputSequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput

    struct AsyncIterator: AsyncIteratorProtocol {
        let reader: BatchSpeechAudioSliceReader

        mutating func next() async throws -> AnalyzerInput? {
            try await reader.next()
        }
    }

    private let reader: BatchSpeechAudioSliceReader

    init(
        slices: [BatchSpeechAudioSlice],
        sourceFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat,
        converterFactory: AnalyzerInputConverterFactory = { sourceFormat, analyzerFormat in
            try AVAudioAnalyzerInputConverter(
                sourceFormat: sourceFormat,
                analyzerFormat: analyzerFormat
            )
        }
    ) throws {
        reader = try BatchSpeechAudioSliceReader(
            slices: slices,
            sourceFormat: sourceFormat,
            analyzerFormat: analyzerFormat,
            converter: converterFactory(sourceFormat, analyzerFormat)
        )
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(reader: reader)
    }
}

actor BatchSpeechAudioSliceReader {
    private static let bufferCapacity: AVAudioFrameCount = 16384

    private let slices: [BatchSpeechAudioSlice]
    private let sourceFormat: AVAudioFormat
    private let analyzerFormat: AVAudioFormat
    private let converter: any AnalyzerInputConverting
    private var sliceIndex = 0
    private var currentFile: AVAudioFile?
    private var remainingFrameCount: Int64 = 0
    private var nextAnalyzerFrame: Int64 = 0
    private var pendingInputs: [AnalyzerInput] = []
    private var didFinishConverter = false

    init(
        slices: [BatchSpeechAudioSlice],
        sourceFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat,
        converter: any AnalyzerInputConverting
    ) throws {
        guard !slices.isEmpty else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        self.slices = slices
        self.sourceFormat = sourceFormat
        self.analyzerFormat = analyzerFormat
        self.converter = converter
    }

    func next() throws -> AnalyzerInput? {
        try Task.checkCancellation()
        if !pendingInputs.isEmpty {
            return pendingInputs.removeFirst()
        }
        while true {
            if remainingFrameCount > 0 {
                if let input = try readNextBuffer() {
                    return input
                }
                continue
            }
            currentFile = nil
            if sliceIndex < slices.count {
                try openNextSlice()
                continue
            }
            guard !didFinishConverter else { return nil }
            didFinishConverter = true
            pendingInputs = try converter.finish()
            guard !pendingInputs.isEmpty else { return nil }
            return pendingInputs.removeFirst()
        }
    }

    private func openNextSlice() throws {
        let slice = slices[sliceIndex]
        sliceIndex += 1
        guard slice.startFrame >= 0, slice.frameCount > 0 else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        let audioFile = try AVAudioFile(forReading: slice.audioURL)
        guard audioFile.processingFormat == sourceFormat,
              slice.startFrame < audioFile.length,
              slice.frameCount <= audioFile.length - slice.startFrame else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        audioFile.framePosition = slice.startFrame
        currentFile = audioFile
        remainingFrameCount = slice.frameCount
    }

    private func readNextBuffer() throws -> AnalyzerInput? {
        guard let currentFile else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        let requestedFrameCount = AVAudioFrameCount(
            min(Int64(Self.bufferCapacity), remainingFrameCount)
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: requestedFrameCount
        ) else {
            throw BatchSpeechTranscriberError.audioFormatUnavailable
        }
        try currentFile.read(into: buffer, frameCount: requestedFrameCount)
        guard buffer.frameLength > 0 else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        remainingFrameCount -= Int64(buffer.frameLength)
        let startTime = CMTime(
            value: nextAnalyzerFrame,
            timescale: CMTimeScale(analyzerFormat.sampleRate.rounded())
        )
        pendingInputs = try converter.convert(buffer, at: startTime)
        nextAnalyzerFrame += pendingInputs.reduce(0) { frames, input in
            frames + Int64(input.buffer.frameLength)
        }
        return pendingInputs.isEmpty ? nil : pendingInputs.removeFirst()
    }
}
