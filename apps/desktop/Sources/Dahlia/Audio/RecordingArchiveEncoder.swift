@preconcurrency import AVFoundation
import CryptoKit
import Foundation

/// Streams verified PCM into one AAC file per source. Capture remains PCM and never waits for this work.
enum RecordingArchiveEncoder {
    static let sampleRate = 16000
    /// Native AAC at 16 kHz mono rejects 64/96 kbps; retain the original sample rate.
    static let bitRate = 48000
    /// Enable only after the documented Apple Speech / Whisper corpus acceptance check passes.
    static let qualityValidatedForSourceDeletion = false

    struct Prepared: Codable, Sendable {
        let relativePath: String
        let size: Int64
        let checksum: String
        let manifest: RecordingArchiveManifest
    }

    static func encode(
        _ segments: [RecordingAudioStore.VerifiedSegment],
        relativePath: String,
        root: URL,
        bitRate: Int = bitRate
    ) throws -> Prepared {
        guard let destination = BatchAudioStorage.safeURL(baseURL: root, relativePath: relativePath),
              !segments.isEmpty else { throw RecordingAudioStoreError.invalidPath }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let partial = destination.deletingPathExtension().appendingPathExtension("partial.m4a")
        if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
        let manifest = try write(segments, to: partial, bitRate: bitRate)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
        try validate(partial, manifest: manifest)
        let checksum = try checksum(partial)
        let size = try fileSize(partial)
        guard size <= 1024 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        // Only derived output is replaced; the verified source CAFs are still protected.
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partial, to: destination)
        return Prepared(relativePath: relativePath, size: size, checksum: checksum, manifest: manifest)
    }

    private static func write(_ segments: [RecordingAudioStore.VerifiedSegment], to url: URL, bitRate: Int) throws -> RecordingArchiveManifest {
        let output = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_VariableConstrained,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        var frames: Int64 = 0
        var ranges: [RecordingArchiveManifest.Range] = []
        for verified in segments.sorted(by: { $0.segment.segmentIndex < $1.segment.segmentIndex }) {
            try Task.checkCancellation()
            let record = verified.segment
            guard record.sampleRate == Double(sampleRate), record.channelCount == 1,
                  let length = record.sealedFrameCount else { throw RecordingAudioStoreError.invalidState }
            let start = Int64((record.sessionStartOffsetSeconds * Double(sampleRate)).rounded())
            guard start >= frames, start + length <= Int64(sampleRate) * 60 * 60 * 48 else { throw RecordingAudioStoreError.invalidState }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 16384) else {
                throw RecordingAudioStoreError.invalidState
            }
            while frames < start {
                try Task.checkCancellation()
                buffer.frameLength = AVAudioFrameCount(min(16384, start - frames))
                buffer.floatChannelData![0].update(repeating: 0, count: Int(buffer.frameLength))
                try output.write(from: buffer)
                frames += Int64(buffer.frameLength)
            }
            let input = try AVAudioFile(forReading: verified.url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard input.length == length else { throw RecordingAudioStoreError.integrityMismatch }
            while input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { throw RecordingAudioStoreError.integrityMismatch }
                try output.write(from: buffer)
                frames += Int64(buffer.frameLength)
            }
            for range in verified.ranges {
                guard let count = range.frameCount, count > 0, range.startFrame >= 0,
                      range.startFrame + count <= length else { throw RecordingAudioStoreError.invalidState }
                ranges.append(.init(
                    startFrame: start + range.startFrame,
                    frameCount: count,
                    sessionOffsetSeconds: range.sessionOffsetSeconds,
                    localeIdentifier: range.localeIdentifier
                ))
            }
        }
        return RecordingArchiveManifest(sampleRate: sampleRate, frameCount: frames, ranges: ranges)
    }

    static func validate(_ url: URL, manifest: RecordingArchiveManifest) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == Double(manifest.sampleRate), file.processingFormat.channelCount == 1,
              file.length == manifest.frameCount,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384) else {
            throw RecordingAudioStoreError.integrityMismatch
        }
        var frames: Int64 = 0
        while frames < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw RecordingAudioStoreError.integrityMismatch }
            frames += Int64(buffer.frameLength)
        }
        guard frames == manifest.frameCount else { throw RecordingAudioStoreError.integrityMismatch }
    }

    static func decode(_ source: URL, to destination: URL, manifest: RecordingArchiveManifest) throws {
        try validate(source, manifest: manifest)
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatInt16, interleaved: false)
        let output = try AVAudioFile(
            forWriting: destination,
            settings: input.processingFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16384) else {
            throw RecordingAudioStoreError.invalidState
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { throw RecordingAudioStoreError.integrityMismatch }
            try output.write(from: buffer)
        }
    }

    static func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        return "SHA-256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            throw RecordingAudioStoreError.missingFile
        }
        return size.int64Value
    }
}
