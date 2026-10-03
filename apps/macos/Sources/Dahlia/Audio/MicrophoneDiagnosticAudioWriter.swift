@preconcurrency import AVFoundation
import Foundation
import os

/// 診断中だけ raw / reference / processed PCM を一時 CAF に保存する。
/// 書き込みは capture callback をブロックしない専用 serial queue で直列化する。
final class MicrophoneDiagnosticAudioWriter: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.dahlia", category: "MicrophoneDiagnosticAudio")

    let directoryURL: URL
    let rawAudioURL: URL?
    let referenceAudioURL: URL?
    let processedAudioURL: URL?

    private let queue = DispatchQueue(label: "com.dahlia.microphone-diagnostic-audio-writer", qos: .utility)
    private var rawFile: AVAudioFile?
    private var referenceFile: AVAudioFile?
    private var processedFile: AVAudioFile?
    private var failureHandler: (@Sendable (Error) -> Void)?
    private var didReportFailure = false

    init(
        rawFormat: AVAudioFormat?,
        processedFormat: AVAudioFormat?,
        referenceFormat: AVAudioFormat? = nil,
        rootDirectory: URL = FileManager.default.temporaryDirectory
    ) throws {
        let directoryURL = rootDirectory
            .appending(path: "Dahlia", directoryHint: .isDirectory)
            .appending(path: "MicrophoneDiagnostics", directoryHint: .isDirectory)
            .appending(path: UUID.v7().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            self.directoryURL = directoryURL

            let rawOutput = try Self.makeAudioFile(named: "raw.caf", format: rawFormat, in: directoryURL)
            rawAudioURL = rawOutput.url
            rawFile = rawOutput.file

            let referenceOutput = try Self.makeAudioFile(
                named: "reference.caf",
                format: referenceFormat,
                in: directoryURL
            )
            referenceAudioURL = referenceOutput.url
            referenceFile = referenceOutput.file

            let processedOutput = try Self.makeAudioFile(
                named: "processed.caf",
                format: processedFormat,
                in: directoryURL
            )
            processedAudioURL = processedOutput.url
            processedFile = processedOutput.file
        } catch {
            throw AudioCaptureError.diagnosticAudioOutputUnavailable
        }
    }

    var onFailure: (@Sendable (Error) -> Void)? {
        get { queue.sync { failureHandler } }
        set { queue.sync { failureHandler = newValue } }
    }

    func appendRaw(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            write(buffer, to: rawFile)
        }
    }

    func appendProcessed(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            write(buffer, to: processedFile)
        }
    }

    func appendReference(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            write(buffer, to: referenceFile)
        }
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                rawFile = nil
                referenceFile = nil
                processedFile = nil
                continuation.resume()
            }
        }
    }

    private static func makeAudioFile(
        named fileName: String,
        format: AVAudioFormat?,
        in directoryURL: URL
    ) throws -> (url: URL?, file: AVAudioFile?) {
        guard let format else { return (nil, nil) }
        let url = directoryURL.appending(path: fileName, directoryHint: .notDirectory)
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        return (url, file)
    }

    private func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile?) {
        guard let file else { return }
        do {
            try file.write(from: buffer)
        } catch {
            guard !didReportFailure else { return }
            didReportFailure = true
            Self.logger.error("Failed to write diagnostic audio: \(error.localizedDescription, privacy: .public)")
            failureHandler?(error)
        }
    }
}
