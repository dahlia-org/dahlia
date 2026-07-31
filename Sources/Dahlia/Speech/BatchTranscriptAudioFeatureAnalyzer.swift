@preconcurrency import AVFoundation
import Foundation

struct BatchTranscriptAudioFeatureAnalysis: Sendable {
    let features: [TranscriptAudioFeatures?]
    let invalidRecognitionCount: Int
}

protocol BatchTranscriptAudioFeatureAnalyzing: Sendable {
    func analyze(
        recognitions: [BatchSpeechRecognition],
        audioURL: URL
    ) throws -> BatchTranscriptAudioFeatureAnalysis

    func analyze(
        recognitions: [BatchSpeechRecognition],
        audioSlices: [BatchSpeechAudioSlice]
    ) throws -> BatchTranscriptAudioFeatureAnalysis
}

enum BatchTranscriptAudioFeatureAnalyzerError: LocalizedError {
    case audioFormatUnavailable
    case extractionFailed
    case invalidAudioRange
    case invalidRecognitionRanges(count: Int)

    var errorDescription: String? {
        switch self {
        case .audioFormatUnavailable:
            "Audio format is unavailable for transcript feature analysis."
        case .extractionFailed:
            "Transcript audio feature analysis failed."
        case .invalidAudioRange:
            "Audio range is invalid for transcript feature analysis."
        case let .invalidRecognitionRanges(count):
            "\(count) transcript ranges could not be matched for audio feature analysis."
        }
    }
}

enum BatchTranscriptAudioFeatureExtraction {
    static func bestEffort(
        recognitions: [BatchSpeechRecognition],
        audioURL: URL,
        source: RecordingAudioSource,
        analyzer: any BatchTranscriptAudioFeatureAnalyzing
    ) async throws -> [TranscriptAudioFeatures?] {
        try await bestEffort(
            recognitionCount: recognitions.count,
            source: source
        ) {
            try analyzer.analyze(recognitions: recognitions, audioURL: audioURL)
        }
    }

    static func bestEffort(
        recognitions: [BatchSpeechRecognition],
        audioSlices: [BatchSpeechAudioSlice],
        source: RecordingAudioSource,
        analyzer: any BatchTranscriptAudioFeatureAnalyzing
    ) async throws -> [TranscriptAudioFeatures?] {
        try await bestEffort(
            recognitionCount: recognitions.count,
            source: source
        ) {
            try analyzer.analyze(recognitions: recognitions, audioSlices: audioSlices)
        }
    }

    private static func bestEffort(
        recognitionCount: Int,
        source: RecordingAudioSource,
        operation: @escaping @Sendable () throws -> BatchTranscriptAudioFeatureAnalysis
    ) async throws -> [TranscriptAudioFeatures?] {
        guard recognitionCount > 0 else { return [] }
        let task = Task.detached(priority: .utility, operation: operation)
        do {
            let analysis = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if analysis.invalidRecognitionCount > 0 {
                ErrorReportingService.capture(
                    BatchTranscriptAudioFeatureAnalyzerError.invalidRecognitionRanges(
                        count: analysis.invalidRecognitionCount
                    ),
                    context: [
                        "source": "batchTranscriptAudioFeatures",
                        "audioSource": source.rawValue,
                    ]
                )
            }
            return analysis.features
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            ErrorReportingService.capture(
                BatchTranscriptAudioFeatureAnalyzerError.extractionFailed,
                context: [
                    "source": "batchTranscriptAudioFeatures",
                    "audioSource": source.rawValue,
                ]
            )
            return Array(repeating: nil, count: recognitionCount)
        }
    }
}

struct BatchTranscriptAudioFeatureAnalyzer: BatchTranscriptAudioFeatureAnalyzing {
    static let windowDuration: TimeInterval = 0.04
    static let hopDuration: TimeInterval = 0.02
    static let activeGateDecibels = -50.0
    static let minimumPitchHertz = 60.0
    static let maximumPitchHertz = 500.0
    static let minimumPitchCorrelation = 0.6

    private static let readCapacity: AVAudioFrameCount = 4096

    func analyze(
        recognitions: [BatchSpeechRecognition],
        audioURL: URL
    ) throws -> BatchTranscriptAudioFeatureAnalysis {
        let audioFile = try AVAudioFile(forReading: audioURL)
        return try analyze(
            recognitions: recognitions,
            audioSlices: [
                BatchSpeechAudioSlice(
                    audioURL: audioURL,
                    startFrame: 0,
                    frameCount: audioFile.length
                ),
            ]
        )
    }

    func analyze(
        recognitions: [BatchSpeechRecognition],
        audioSlices: [BatchSpeechAudioSlice]
    ) throws -> BatchTranscriptAudioFeatureAnalysis {
        guard !audioSlices.isEmpty else {
            return BatchTranscriptAudioFeatureAnalysis(
                features: Array(repeating: nil, count: recognitions.count),
                invalidRecognitionCount: recognitions.count
            )
        }

        var processor: FeatureWindowProcessor?
        for slice in audioSlices {
            try Task.checkCancellation()
            let audioFile = try AVAudioFile(forReading: slice.audioURL)
            let format = audioFile.processingFormat
            guard format.sampleRate > 0, format.channelCount == 1 else {
                throw BatchTranscriptAudioFeatureAnalyzerError.audioFormatUnavailable
            }
            guard slice.startFrame >= 0,
                  slice.frameCount > 0,
                  slice.startFrame <= audioFile.length - slice.frameCount else {
                throw BatchTranscriptAudioFeatureAnalyzerError.invalidAudioRange
            }

            if processor == nil {
                processor = FeatureWindowProcessor(
                    recognitions: recognitions,
                    sampleRate: format.sampleRate
                )
            } else if processor?.sampleRate != format.sampleRate {
                throw BatchTranscriptAudioFeatureAnalyzerError.audioFormatUnavailable
            }

            audioFile.framePosition = slice.startFrame
            var remainingFrameCount = slice.frameCount
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: Self.readCapacity
            ) else {
                throw BatchTranscriptAudioFeatureAnalyzerError.audioFormatUnavailable
            }
            while remainingFrameCount > 0 {
                try Task.checkCancellation()
                let requestedFrameCount = AVAudioFrameCount(
                    min(Int64(Self.readCapacity), remainingFrameCount)
                )
                try audioFile.read(into: buffer, frameCount: requestedFrameCount)
                guard buffer.frameLength > 0 else {
                    throw BatchTranscriptAudioFeatureAnalyzerError.invalidAudioRange
                }
                try processor?.consume(Self.samples(from: buffer))
                remainingFrameCount -= Int64(buffer.frameLength)
            }
        }

        guard var processor else {
            throw BatchTranscriptAudioFeatureAnalyzerError.audioFormatUnavailable
        }
        return processor.finish()
    }

    private static func samples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        let frameCount = Int(buffer.frameLength)
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channel = buffer.floatChannelData?[0] else {
                throw BatchTranscriptAudioFeatureAnalyzerError.audioFormatUnavailable
            }
            return Array(UnsafeBufferPointer(start: channel, count: frameCount))
        case .pcmFormatInt16:
            guard let channel = buffer.int16ChannelData?[0] else {
                throw BatchTranscriptAudioFeatureAnalyzerError.audioFormatUnavailable
            }
            return UnsafeBufferPointer(start: channel, count: frameCount).map {
                Float($0) / Float(Int16.max)
            }
        default:
            throw BatchTranscriptAudioFeatureAnalyzerError.audioFormatUnavailable
        }
    }
}

private struct FeatureWindowProcessor {
    struct Interval {
        let recognitionIndex: Int
        let startFrame: Int64
        let endFrame: Int64
    }

    struct Accumulator {
        var analysisFrameCount = 0
        var activeFrameCount = 0
        var activeMeanSquareSum = 0.0
        var pitches: [Double] = []

        func features() -> TranscriptAudioFeatures {
            let voicedFrameRatio = analysisFrameCount > 0
                ? Double(activeFrameCount) / Double(analysisFrameCount)
                : 0
            let activeRmsDecibels = activeFrameCount > 0
                ? AudioLevelCalculator.rmsDecibels(
                    rootMeanSquare: sqrt(activeMeanSquareSum / Double(activeFrameCount))
                )
                : nil
            let sortedPitches = pitches.sorted()
            let medianPitchHertz = Self.quantile(0.5, values: sortedPitches)
            let pitchSpreadHertz: Double? = if sortedPitches.count >= 4,
                                               let lower = Self.quantile(0.25, values: sortedPitches),
                                               let upper = Self.quantile(0.75, values: sortedPitches) {
                upper - lower
            } else {
                nil
            }
            return TranscriptAudioFeatures(
                activeRmsDecibels: activeRmsDecibels,
                medianPitchHertz: medianPitchHertz,
                voicedFrameRatio: voicedFrameRatio,
                pitchSpreadHertz: pitchSpreadHertz
            )
        }

        private static func quantile(_ probability: Double, values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let position = probability * Double(values.count - 1)
            let lowerIndex = Int(floor(position))
            let upperIndex = Int(ceil(position))
            guard lowerIndex != upperIndex else { return values[lowerIndex] }
            let fraction = position - Double(lowerIndex)
            return values[lowerIndex] + ((values[upperIndex] - values[lowerIndex]) * fraction)
        }
    }

    let sampleRate: Double
    private let windowSize: Int
    private let hopSize: Int
    private let intervals: [Interval]
    private let initiallyInvalidRecognitionIndices: Set<Int>
    private var accumulators: [Accumulator]
    private var pendingSamples: [Float] = []
    private var pendingStartIndex = 0
    private var nextWindowStartFrame: Int64 = 0
    private var receivedFrameCount: Int64 = 0
    private var nextIntervalIndex = 0
    private var activeIntervals: [Interval] = []

    init(recognitions: [BatchSpeechRecognition], sampleRate: Double) {
        self.sampleRate = sampleRate
        windowSize = max(1, Int((sampleRate * BatchTranscriptAudioFeatureAnalyzer.windowDuration).rounded()))
        hopSize = max(1, Int((sampleRate * BatchTranscriptAudioFeatureAnalyzer.hopDuration).rounded()))
        accumulators = Array(repeating: Accumulator(), count: recognitions.count)

        var intervals: [Interval] = []
        var invalidIndices: Set<Int> = []
        for (index, recognition) in recognitions.enumerated() {
            guard recognition.startSeconds.isFinite,
                  recognition.endSeconds.isFinite,
                  recognition.startSeconds >= 0,
                  recognition.endSeconds > recognition.startSeconds,
                  let startFrame = Int64(exactly: floor(recognition.startSeconds * sampleRate)),
                  let endFrame = Int64(exactly: ceil(recognition.endSeconds * sampleRate)) else {
                invalidIndices.insert(index)
                continue
            }
            intervals.append(Interval(
                recognitionIndex: index,
                startFrame: startFrame,
                endFrame: endFrame
            ))
        }
        self.intervals = intervals.sorted {
            if $0.startFrame == $1.startFrame {
                return $0.endFrame < $1.endFrame
            }
            return $0.startFrame < $1.startFrame
        }
        initiallyInvalidRecognitionIndices = invalidIndices
    }

    mutating func consume(_ samples: [Float]) throws {
        try Task.checkCancellation()
        guard !samples.isEmpty else { return }
        pendingSamples.append(contentsOf: samples)
        receivedFrameCount += Int64(samples.count)

        while pendingSamples.count - pendingStartIndex >= windowSize {
            let window = Array(
                pendingSamples[pendingStartIndex ..< pendingStartIndex + windowSize]
            )
            process(window: window, actualSampleCount: windowSize)
            pendingStartIndex += hopSize
            nextWindowStartFrame += Int64(hopSize)
        }

        if pendingStartIndex >= 16384 {
            pendingSamples.removeFirst(pendingStartIndex)
            pendingStartIndex = 0
        }
    }

    mutating func finish() -> BatchTranscriptAudioFeatureAnalysis {
        let remainingSampleCount = pendingSamples.count - pendingStartIndex
        if remainingSampleCount > 0, nextWindowStartFrame < receivedFrameCount {
            var window = Array(pendingSamples[pendingStartIndex...])
            let actualSampleCount = window.count
            if window.count < windowSize {
                window.append(contentsOf: repeatElement(0, count: windowSize - window.count))
            }
            process(window: window, actualSampleCount: actualSampleCount)
        }

        var invalidRecognitionIndices = initiallyInvalidRecognitionIndices
        for interval in intervals where interval.endFrame > receivedFrameCount + 1 {
            invalidRecognitionIndices.insert(interval.recognitionIndex)
        }
        let features = accumulators.indices.map { index -> TranscriptAudioFeatures? in
            guard !invalidRecognitionIndices.contains(index) else { return nil }
            return accumulators[index].features()
        }
        return BatchTranscriptAudioFeatureAnalysis(
            features: features,
            invalidRecognitionCount: invalidRecognitionIndices.count
        )
    }

    private mutating func process(window: [Float], actualSampleCount: Int) {
        guard actualSampleCount > 0 else { return }
        let windowStartFrame = nextWindowStartFrame
        let windowEndFrame = windowStartFrame + Int64(actualSampleCount)
        activeIntervals.removeAll { $0.endFrame <= windowStartFrame }
        while nextIntervalIndex < intervals.count,
              intervals[nextIntervalIndex].startFrame < windowEndFrame {
            let interval = intervals[nextIntervalIndex]
            nextIntervalIndex += 1
            if interval.endFrame > windowStartFrame {
                activeIntervals.append(interval)
            }
        }
        guard !activeIntervals.isEmpty else { return }

        var didEstimateFullWindowPitch = false
        var fullWindowPitch: Double?
        for interval in activeIntervals {
            let overlapStartFrame = max(windowStartFrame, interval.startFrame)
            let overlapEndFrame = min(windowEndFrame, interval.endFrame)
            let overlapStartIndex = Int(overlapStartFrame - windowStartFrame)
            let overlapEndIndex = Int(overlapEndFrame - windowStartFrame)
            guard overlapStartIndex < overlapEndIndex else { continue }
            let overlapSamples = window[overlapStartIndex ..< overlapEndIndex]
            let meanSquare = overlapSamples.reduce(0.0) {
                $0 + (Double($1) * Double($1))
            } / Double(overlapSamples.count)
            let decibels = AudioLevelCalculator.rmsDecibels(
                rootMeanSquare: sqrt(meanSquare)
            )
            let isActive = decibels >= BatchTranscriptAudioFeatureAnalyzer.activeGateDecibels

            accumulators[interval.recognitionIndex].analysisFrameCount += 1
            if isActive {
                accumulators[interval.recognitionIndex].activeFrameCount += 1
                accumulators[interval.recognitionIndex].activeMeanSquareSum += meanSquare
            }
            if isActive, overlapSamples.count == windowSize {
                if !didEstimateFullWindowPitch {
                    fullWindowPitch = BatchPitchEstimator.estimate(
                        in: window,
                        sampleRate: sampleRate
                    )
                    didEstimateFullWindowPitch = true
                }
                if let fullWindowPitch {
                    accumulators[interval.recognitionIndex].pitches.append(fullWindowPitch)
                }
            }
        }
    }
}
