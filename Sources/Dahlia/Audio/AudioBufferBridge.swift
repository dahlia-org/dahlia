@preconcurrency import AVFoundation
import CoreMedia
import os
import Speech

/// オーディオキャプチャコールバックから SpeechAnalyzer が消費する
/// AsyncStream<AnalyzerInput> へのブリッジ。
/// AudioCaptureManager / SystemAudioCaptureManager の onAudioBuffer コールバックから
/// append(_:) を呼び出し、SpeechAnalyzer.start(inputSequence:) に stream を渡す。
final class AudioBufferBridge: Sendable {
    enum BufferingMode: Equatable {
        case lossless
        case lowLatency(maximumInputCount: Int)
    }

    let stream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation

    private let inputConverter: AnalyzerInputConverting?
    private let bufferingMode: BufferingMode
    private let lock = OSAllocatedUnfairLock()

    /// Capture と SpeechAnalyzer の形式が異なる場合に、ライブ分岐内でのみ変換する。
    /// batch + live では固定形式の CAF 録音を維持しつつ、同じバッファをライブ認識に利用できる。
    init(
        sourceFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat,
        inputConverter: AnalyzerInputConverting? = nil,
        bufferingMode: BufferingMode = .lossless
    ) throws {
        self.bufferingMode = bufferingMode
        if sourceFormat == analyzerFormat {
            self.inputConverter = nil
        } else {
            guard let inputConverter else {
                throw AudioCaptureError.converterCreationFailed
            }
            self.inputConverter = inputConverter
        }

        let (stream, continuation) = Self.makeStream(bufferingMode: bufferingMode)
        self.stream = stream
        self.continuation = continuation
    }

    /// オーディオキャプチャコールバックから呼ばれる。スレッドセーフ。
    @discardableResult
    func append(_ chunk: CapturedAudioChunk) -> Bool {
        lock.withLock {
            let inputs: [AnalyzerInput]
            do {
                if let inputConverter {
                    inputs = try inputConverter.convert(chunk.buffer, at: chunk.sessionRelativeStartTime)
                } else {
                    inputs = [AnalyzerInput(
                        buffer: chunk.buffer,
                        bufferStartTime: chunk.sessionRelativeStartTime
                    )]
                }
            } catch {
                return false
            }

            var accepted = true
            for input in inputs {
                switch continuation.yield(input) {
                case .enqueued:
                    break
                case .dropped:
                    if case .lossless = bufferingMode {
                        accepted = false
                    }
                case .terminated:
                    accepted = false
                @unknown default:
                    accepted = false
                }
            }
            return accepted
        }
    }

    /// オーディオ入力の終了を通知する。
    func finish() {
        lock.withLock {
            if let inputConverter,
               let pendingInputs = try? inputConverter.finish() {
                for input in pendingInputs {
                    continuation.yield(input)
                }
            }
            continuation.finish()
        }
    }

    private static func makeStream(
        bufferingMode: BufferingMode
    ) -> (stream: AsyncStream<AnalyzerInput>, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        let bufferingPolicy: AsyncStream<AnalyzerInput>.Continuation.BufferingPolicy = switch bufferingMode {
        case .lossless:
            .unbounded
        case let .lowLatency(maximumInputCount):
            .bufferingNewest(max(1, maximumInputCount))
        }
        return AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: bufferingPolicy)
    }
}
