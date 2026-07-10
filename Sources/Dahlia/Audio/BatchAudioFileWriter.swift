@preconcurrency import AVFoundation
import Foundation
import os

/// 音声コールバックをブロックせず、CAFへ直列に追記するWriter。
actor BatchAudioFileWriter {
    private static let maximumBufferedChunkCount = 256

    private struct AudioChunk {
        let data: Data
        let frameCount: AVAudioFrameCount
    }

    private struct CallbackState {
        var appendedFrameCount: Int64 = 0
        var errorMessage: String?
        var isAcceptingBuffers = true
    }

    // SwiftFormatのmodifier順と、無効なSwiftLint modifier_order設定のfallbackが競合する。
    // swiftlint:disable modifier_order
    private nonisolated let continuation: AsyncStream<AudioChunk>.Continuation
    private nonisolated let callbackState = OSAllocatedUnfairLock(initialState: CallbackState())
    // swiftlint:enable modifier_order

    private let stream: AsyncStream<AudioChunk>
    private let partialURL: URL
    private let finalURL: URL
    private let format: AVAudioFormat
    private var audioFile: AVAudioFile?
    private var writerTask: Task<Void, Never>?
    private var writeError: Error?

    nonisolated var appendedFrameCount: Int64 {
        callbackState.withLock { $0.appendedFrameCount }
    }

    init(
        partialURL: URL,
        finalURL: URL,
        format: AVAudioFormat,
        maximumBufferedChunkCount: Int = BatchAudioFileWriter.maximumBufferedChunkCount
    ) {
        let pair = AsyncStream.makeStream(
            of: AudioChunk.self,
            bufferingPolicy: .bufferingNewest(max(1, maximumBufferedChunkCount))
        )
        stream = pair.stream
        continuation = pair.continuation
        self.partialURL = partialURL
        self.finalURL = finalURL
        self.format = format
    }

    func start() throws {
        try FileManager.default.createDirectory(
            at: partialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: partialURL.path) {
            try FileManager.default.removeItem(at: partialURL)
        }
        audioFile = try AVAudioFile(
            forWriting: partialURL,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )

        writerTask = Task { [weak self, stream] in
            for await chunk in stream {
                await self?.consume(chunk)
            }
        }
    }

    nonisolated func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatInt16,
              buffer.format.channelCount == 1,
              let channelData = buffer.int16ChannelData else {
            callbackState.withLock { $0.errorMessage = BatchAudioFileWriterError.incompatibleBuffer.localizedDescription }
            return
        }

        let frameCount = buffer.frameLength
        guard frameCount > 0 else { return }
        let byteCount = Int(frameCount) * MemoryLayout<Int16>.size
        let data = Data(bytes: channelData[0], count: byteCount)
        callbackState.withLock { state in
            guard state.isAcceptingBuffers else { return }
            switch continuation.yield(AudioChunk(data: data, frameCount: frameCount)) {
            case .enqueued:
                state.appendedFrameCount += Int64(frameCount)
            case .dropped:
                state.errorMessage = L10n.batchAudioBufferOverflow
            case .terminated:
                state.errorMessage = L10n.batchAudioWriterClosed
            @unknown default:
                state.errorMessage = L10n.batchAudioWriterClosed
            }
        }
    }

    /// capture を切り離した後に呼び、range と CAF のフレーム数を固定する。
    @discardableResult
    nonisolated func seal() -> Int64 {
        callbackState.withLock { state in
            state.isAcceptingBuffers = false
            return state.appendedFrameCount
        }
    }

    func finish() async throws -> Int64 {
        let finalFrameCount = seal()
        await closeWriter()

        if let callbackMessage = callbackState.withLock({ $0.errorMessage }) {
            throw BatchAudioFileWriterError.writeFailed(callbackMessage)
        }
        if let writeError {
            throw BatchAudioFileWriterError.writeFailed(writeError.localizedDescription)
        }

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        return finalFrameCount
    }

    func cancelAndDelete() async {
        seal()
        await closeWriter()
        try? FileManager.default.removeItem(at: partialURL)
        try? FileManager.default.removeItem(at: finalURL)
    }

    private func closeWriter() async {
        continuation.finish()
        await writerTask?.value
        writerTask = nil
        audioFile = nil
    }

    private func write(_ chunk: AudioChunk) throws {
        guard writeError == nil, let audioFile else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk.frameCount),
              let channelData = buffer.int16ChannelData else {
            throw BatchAudioFileWriterError.incompatibleBuffer
        }

        let destination = UnsafeMutableRawBufferPointer(
            start: channelData[0],
            count: chunk.data.count
        )
        chunk.data.copyBytes(to: destination)
        buffer.frameLength = chunk.frameCount
        try audioFile.write(from: buffer)
    }

    private func consume(_ chunk: AudioChunk) {
        do {
            try write(chunk)
        } catch {
            writeError = error
        }
    }
}
