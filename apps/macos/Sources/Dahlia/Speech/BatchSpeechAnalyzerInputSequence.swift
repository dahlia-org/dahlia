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
        onSliceConsumed: @escaping @Sendable (Int) async -> Void = { _ in },
        onBufferConsumed: @escaping @Sendable () async -> Void = {},
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
            converter: converterFactory(sourceFormat, analyzerFormat),
            onSliceConsumed: onSliceConsumed,
            onBufferConsumed: onBufferConsumed
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
    private let onSliceConsumed: @Sendable (Int) async -> Void
    private let onBufferConsumed: @Sendable () async -> Void
    private var sliceIndex = 0
    private var currentFile: AVAudioFile?
    private var remainingFrameCount: Int64 = 0
    private var nextAnalyzerFrame: Int64 = 0
    private var pendingInputs: [AnalyzerInput] = []
    private var pendingCompletedSliceIndex: Int?
    private var didFinishConverter = false

    init(
        slices: [BatchSpeechAudioSlice],
        sourceFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat,
        converter: any AnalyzerInputConverting,
        onSliceConsumed: @escaping @Sendable (Int) async -> Void,
        onBufferConsumed: @escaping @Sendable () async -> Void
    ) throws {
        guard !slices.isEmpty else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        self.slices = slices
        self.sourceFormat = sourceFormat
        self.analyzerFormat = analyzerFormat
        self.converter = converter
        self.onSliceConsumed = onSliceConsumed
        self.onBufferConsumed = onBufferConsumed
    }

    func next() async throws -> AnalyzerInput? {
        while true {
            try Task.checkCancellation()
            if !pendingInputs.isEmpty {
                return pendingInputs.removeFirst()
            }
            if let completedSliceIndex = pendingCompletedSliceIndex {
                pendingCompletedSliceIndex = nil
                currentFile = nil
                await onSliceConsumed(completedSliceIndex)
                continue
            }
            if remainingFrameCount > 0 {
                let input = try readNextBuffer()
                await onBufferConsumed()
                if let input {
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
        if remainingFrameCount == 0 {
            pendingCompletedSliceIndex = sliceIndex - 1
        }
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
