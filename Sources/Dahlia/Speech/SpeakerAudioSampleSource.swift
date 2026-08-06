@preconcurrency import AVFoundation
import Foundation

struct SpeakerAudioFileSlice: Equatable, Sendable {
    let source: RecordingAudioSource
    let url: URL
    let startFrame: Int64
    let frameCount: Int64
    let sessionOffsetSeconds: TimeInterval
}

struct MemoryMappedAudioSampleSource: Sendable {
    static let channelCount = 1
    static let sampleEncoding = "Float32"

    let sampleRate: Int
    let temporaryFileURL: URL
    let sampleCount: Int

    private let mappedData: Data

    init(temporaryFileURL: URL, sampleRate: Int = 16000) throws {
        mappedData = try Data(contentsOf: temporaryFileURL, options: .alwaysMapped)
        self.temporaryFileURL = temporaryFileURL
        self.sampleRate = sampleRate
        sampleCount = mappedData.count / MemoryLayout<Float>.stride
    }

    func copySamples(
        into destination: UnsafeMutablePointer<Float>,
        offset: Int,
        count: Int
    ) throws {
        guard count > 0, offset >= 0, offset < sampleCount else { return }
        let availableCount = min(count, sampleCount - offset)
        mappedData.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Float.self)
            guard let baseAddress = samples.baseAddress else { return }
            destination.update(from: baseAddress.advanced(by: offset), count: availableCount)
        }
    }

    func cleanup(fileManager: FileManager = .default) throws {
        try fileManager.removeItem(at: temporaryFileURL)
    }
}

enum SpeakerAudioSampleSourceError: Error, Equatable {
    case invalidAudioFormat
    case invalidRange
    case conversionFailed
    case temporaryFileCreationFailed
}

actor SpeakerAudioSampleSourceConverter {
    static let sampleRate = 16000

    private let temporaryDirectoryURL: URL
    private let fileManager: FileManager

    init(
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        self.temporaryDirectoryURL = temporaryDirectoryURL
        self.fileManager = fileManager
    }

    func convert(
        _ slices: [SpeakerAudioFileSlice]
    ) throws -> [RecordingAudioSource: MemoryMappedAudioSampleSource] {
        var sources: [RecordingAudioSource: MemoryMappedAudioSampleSource] = [:]
        do {
            for source in [RecordingAudioSource.microphone, .system] {
                let sourceSlices = slices
                    .filter { $0.source == source }
                    .sorted { $0.sessionOffsetSeconds < $1.sessionOffsetSeconds }
                guard !sourceSlices.isEmpty else { continue }
                sources[source] = try convert(sourceSlices, source: source)
            }
            return sources
        } catch {
            for source in sources.values {
                try? source.cleanup(fileManager: fileManager)
            }
            throw error
        }
    }

    private func convert(
        _ slices: [SpeakerAudioFileSlice],
        source: RecordingAudioSource
    ) throws -> MemoryMappedAudioSampleSource {
        let temporaryURL = temporaryDirectoryURL.appending(
            path: "dahlia-speaker-\(source.rawValue)-\(UUID.v7().uuidString).f32"
        )
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw SpeakerAudioSampleSourceError.temporaryFileCreationFailed
        }

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            defer { try? handle.close() }
            var outputFrame = 0

            for slice in slices {
                guard slice.startFrame >= 0,
                      slice.frameCount >= 0,
                      slice.sessionOffsetSeconds >= 0 else {
                    throw SpeakerAudioSampleSourceError.invalidRange
                }
                let intendedFrame = Int((slice.sessionOffsetSeconds * Double(Self.sampleRate)).rounded())
                if intendedFrame > outputFrame {
                    try writeZeros(count: intendedFrame - outputFrame, to: handle)
                    outputFrame = intendedFrame
                }

                let overlapCount = max(0, outputFrame - intendedFrame)
                outputFrame += try writeConvertedSamples(
                    for: slice,
                    droppingFirst: overlapCount,
                    to: handle
                )
            }

            try handle.synchronize()
            try handle.close()
            return try MemoryMappedAudioSampleSource(temporaryFileURL: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func writeConvertedSamples(
        for slice: SpeakerAudioFileSlice,
        droppingFirst droppedFrameCount: Int,
        to handle: FileHandle
    ) throws -> Int {
        let file = try AVAudioFile(forReading: slice.url)
        guard slice.startFrame + slice.frameCount <= file.length,
              let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(Self.sampleRate),
                  channels: 1,
                  interleaved: false
              ) else {
            throw SpeakerAudioSampleSourceError.invalidAudioFormat
        }

        file.framePosition = slice.startFrame
        if file.processingFormat.sampleRate == targetFormat.sampleRate,
           file.processingFormat.channelCount == 1 {
            return try writeFloatSamples(
                from: file,
                frameCount: slice.frameCount,
                droppingFirst: droppedFrameCount,
                to: handle
            )
        }
        guard let converter = AudioConverter.makeConverter(from: file.processingFormat, to: targetFormat) else {
            throw SpeakerAudioSampleSourceError.invalidAudioFormat
        }
        return try writeResampledSamples(
            from: file,
            frameCount: slice.frameCount,
            converter: converter,
            targetFormat: targetFormat,
            droppingFirst: droppedFrameCount,
            to: handle
        )
    }

    private func writeResampledSamples(
        from file: AVAudioFile,
        frameCount: Int64,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        droppingFirst droppedFrameCount: Int,
        to handle: FileHandle
    ) throws -> Int {
        let inputCapacity: AVAudioFrameCount = 16384
        let buffers = try makeConversionBuffers(
            inputFormat: file.processingFormat,
            targetFormat: targetFormat,
            inputCapacity: inputCapacity
        )
        nonisolated(unsafe) var remainingFrames = frameCount
        nonisolated(unsafe) var readError: Error?
        nonisolated(unsafe) let inputBuffer = buffers.input
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            guard remainingFrames > 0 else {
                status.pointee = .endOfStream
                return nil
            }
            do {
                let framesToRead = AVAudioFrameCount(min(Int64(inputCapacity), remainingFrames))
                try file.read(into: inputBuffer, frameCount: framesToRead)
                remainingFrames -= Int64(inputBuffer.frameLength)
                status.pointee = inputBuffer.frameLength > 0 ? .haveData : .endOfStream
                return inputBuffer.frameLength > 0 ? inputBuffer : nil
            } catch {
                readError = error
                status.pointee = .endOfStream
                return nil
            }
        }
        var remainingDroppedFrames = droppedFrameCount
        var writtenFrameCount = 0
        while true {
            buffers.output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(
                to: buffers.output,
                error: &conversionError,
                withInputFrom: inputBlock
            )
            if readError != nil || conversionError != nil || status == .error {
                throw SpeakerAudioSampleSourceError.conversionFailed
            }
            writtenFrameCount += try writeOutputBuffer(
                buffers.output,
                droppingFirst: &remainingDroppedFrames,
                to: handle
            )
            if status == .endOfStream {
                return writtenFrameCount
            }
        }
    }

    private func makeConversionBuffers(
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        inputCapacity: AVAudioFrameCount
    ) throws -> (input: AVAudioPCMBuffer, output: AVAudioPCMBuffer) {
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(inputCapacity) * targetFormat.sampleRate / inputFormat.sampleRate)
        )
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity),
              let output = AVAudioPCMBuffer(
                  pcmFormat: targetFormat,
                  frameCapacity: max(1024, outputCapacity)
              ) else {
            throw SpeakerAudioSampleSourceError.invalidAudioFormat
        }
        return (input, output)
    }

    private func writeOutputBuffer(
        _ buffer: AVAudioPCMBuffer,
        droppingFirst remainingDroppedFrames: inout Int,
        to handle: FileHandle
    ) throws -> Int {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let producedFrameCount = Int(buffer.frameLength)
        let skippedFrameCount = min(remainingDroppedFrames, producedFrameCount)
        remainingDroppedFrames -= skippedFrameCount
        let writtenFrameCount = producedFrameCount - skippedFrameCount
        if writtenFrameCount > 0 {
            try write(
                channel.advanced(by: skippedFrameCount),
                count: writtenFrameCount,
                to: handle
            )
        }
        return writtenFrameCount
    }

    private func writeFloatSamples(
        from file: AVAudioFile,
        frameCount: Int64,
        droppingFirst droppedFrameCount: Int,
        to handle: FileHandle
    ) throws -> Int {
        let capacity: AVAudioFrameCount = 16384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
            throw SpeakerAudioSampleSourceError.invalidAudioFormat
        }
        var remainingFrames = frameCount
        var remainingDroppedFrames = droppedFrameCount
        var writtenFrameCount = 0
        while remainingFrames > 0 {
            let requestedFrameCount = AVAudioFrameCount(min(Int64(capacity), remainingFrames))
            try file.read(into: buffer, frameCount: requestedFrameCount)
            guard let channel = buffer.floatChannelData?[0] else {
                throw SpeakerAudioSampleSourceError.invalidAudioFormat
            }
            let readFrameCount = Int(buffer.frameLength)
            guard readFrameCount > 0 else { break }
            let skippedFrameCount = min(remainingDroppedFrames, readFrameCount)
            remainingDroppedFrames -= skippedFrameCount
            let frameCount = readFrameCount - skippedFrameCount
            if frameCount > 0 {
                try write(
                    channel.advanced(by: skippedFrameCount),
                    count: frameCount,
                    to: handle
                )
                writtenFrameCount += frameCount
            }
            remainingFrames -= Int64(readFrameCount)
        }
        return writtenFrameCount
    }

    private func writeZeros(count: Int, to handle: FileHandle) throws {
        let chunkSize = 16384
        let zeros = [Float](repeating: 0, count: chunkSize)
        var remaining = count
        while remaining > 0 {
            let writtenCount = min(remaining, chunkSize)
            try write(Array(zeros.prefix(writtenCount)), to: handle)
            remaining -= writtenCount
        }
    }

    private func write(_ samples: [Float], to handle: FileHandle) throws {
        try samples.withUnsafeBytes { bytes in
            try handle.write(contentsOf: Data(bytes))
        }
    }

    private func write(
        _ samples: UnsafePointer<Float>,
        count: Int,
        to handle: FileHandle
    ) throws {
        try handle.write(contentsOf: Data(
            bytes: samples,
            count: count * MemoryLayout<Float>.stride
        ))
    }
}
