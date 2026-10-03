@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation
import os
@preconcurrency import ScreenCaptureKit

enum SystemAudioCaptureError: Error, LocalizedError {
    case screenRecordingPermissionDenied
    case noDisplayFound

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            L10n.screenRecordingDenied
        case .noDisplayFound:
            L10n.noDisplayFound
        }
    }
}

/// Serial callback lane whose drain is part of the capture-stop contract.
struct SystemAudioCallbackQueue: Sendable {
    let sampleHandlerQueue: DispatchQueue

    init(label: String = "com.dahlia.systemaudio") {
        self.sampleHandlerQueue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func drain(_ cleanup: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            sampleHandlerQueue.async {
                cleanup()
                continuation.resume()
            }
        }
    }
}

/// Closes admission for callbacks that have not started while allowing an already
/// admitted callback to finish conversion and routing before the queue is drained.
struct SystemAudioSampleAdmission: Sendable {
    private let isAcceptingSamples = OSAllocatedUnfairLock(initialState: true)

    func deactivate() {
        isAcceptingSamples.withLock { $0 = false }
    }

    func performIfAccepting(_ operation: () -> Void) {
        guard isAcceptingSamples.withLock(\.self) else { return }
        operation()
    }
}

/// Owns the mutable ScreenCaptureKit lifecycle. Delegate callbacks enter through a
/// generation-scoped adapter and can only mutate this actor by reporting stream completion.
actor SystemAudioCaptureManager {
    typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer) -> Void
    typealias StreamStoppedHandler = @Sendable (Error?) -> Void

    private struct ActiveCapture {
        let generation: UInt64
        let stream: SCStream
        let adapter: SystemAudioStreamAdapter
    }

    private let onAudioBuffer: AudioBufferHandler
    private let onStreamStopped: StreamStoppedHandler
    private let audioQueue = SystemAudioCallbackQueue()
    private var lifecycle = SystemAudioCaptureLifecycle()
    private var activeCapture: ActiveCapture?
    private var completionWaiters: [
        UInt64: [CheckedContinuation<Result<Void, Error>, Never>]
    ] = [:]

    init(
        onAudioBuffer: @escaping AudioBufferHandler,
        onStreamStopped: @escaping StreamStoppedHandler
    ) {
        self.onAudioBuffer = onAudioBuffer
        self.onStreamStopped = onStreamStopped
    }

    /// 画面収録パーミッションを確認する。
    nonisolated static func requestPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            return false
        }
    }

    /// システム音声キャプチャを開始する。
    func startCapture(targetFormat: AVAudioFormat) async throws {
        guard let generation = lifecycle.beginStart() else {
            throw CancellationError()
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            let startWasCancelled = !lifecycle.canContinueStart(generation: generation)
            lifecycle.abandonStart(generation: generation)
            if startWasCancelled {
                throw CancellationError()
            }
            throw SystemAudioCaptureError.screenRecordingPermissionDenied
        }
        try ensureStartCanContinue(generation: generation)

        guard let display = content.displays.first else {
            lifecycle.abandonStart(generation: generation)
            throw SystemAudioCaptureError.noDisplayFound
        }

        let bundleID = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let configuration = makeConfiguration()
        let adapter = SystemAudioStreamAdapter(
            generation: generation,
            targetFormat: targetFormat,
            onAudioBuffer: onAudioBuffer
        ) { [weak self] generation, error in
            Task {
                await self?.streamDidStop(generation: generation, error: error)
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: adapter)

        do {
            try stream.addStreamOutput(
                adapter,
                type: .audio,
                sampleHandlerQueue: audioQueue.sampleHandlerQueue
            )
            activeCapture = ActiveCapture(
                generation: generation,
                stream: stream,
                adapter: adapter
            )
            try await stream.startCapture()
            try ensureStartCanContinue(generation: generation)
        } catch {
            let startError = error
            adapter.deactivate()
            try? await stopCaptureAndWait()
            throw startError
        }
    }

    /// capture 停止の完了を待ち、要求停止に伴う delegate callback は通知しない。
    func stopCaptureAndWait() async throws {
        guard let request = lifecycle.requestStop() else { return }
        let generation: UInt64
        switch request {
        case let .wait(waitingGeneration):
            try await waitForCompletion(generation: waitingGeneration)
            return
        case let .begin(startedGeneration):
            generation = startedGeneration
        }

        guard let capture = activeCapture, capture.generation == generation else {
            finishCapture(generation: generation, result: .success(()))
            return
        }

        capture.adapter.deactivate()
        let result: Result<Void, Error>
        do {
            try await capture.stream.stopCapture()
            await drainAudioCallbacks(for: capture.adapter)
            result = .success(())
        } catch {
            await drainAudioCallbacks(for: capture.adapter)
            result = .failure(error)
        }
        finishCapture(generation: generation, result: result)
        try result.get()
    }

    private func streamDidStop(generation: UInt64, error: Error?) async {
        guard let capture = activeCapture,
              capture.generation == generation,
              let shouldReport = lifecycle.beginDelegateCompletion(generation: generation)
        else { return }

        capture.adapter.deactivate()
        await drainAudioCallbacks(for: capture.adapter)
        finishCapture(generation: generation, result: .success(()))
        if shouldReport {
            onStreamStopped(error)
        }
    }

    private func waitForCompletion(generation: UInt64) async throws {
        let result = await withCheckedContinuation { continuation in
            completionWaiters[generation, default: []].append(continuation)
        }
        try result.get()
    }

    private func finishCapture(generation: UInt64, result: Result<Void, Error>) {
        if activeCapture?.generation == generation {
            activeCapture = nil
        }
        lifecycle.finishCompletion(generation: generation)
        let waiters = completionWaiters.removeValue(forKey: generation) ?? []
        waiters.forEach { $0.resume(returning: result) }
    }

    private func drainAudioCallbacks(for adapter: SystemAudioStreamAdapter) async {
        await audioQueue.drain {
            adapter.finishDeactivationOnAudioQueue()
        }
    }

    private func ensureStartCanContinue(generation: UInt64) throws {
        guard lifecycle.canContinueStart(generation: generation) else {
            throw CancellationError()
        }
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.excludesCurrentProcessAudio = true
        return configuration
    }
}

/// The only unchecked ScreenCaptureKit boundary in the system-audio path.
///
/// Immutable callbacks are Sendable. Conversion state is confined to the serial audio queue;
/// a small lock only closes admission from lifecycle methods running on other executors.
private final class SystemAudioStreamAdapter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias StopHandler = @Sendable (UInt64, Error?) -> Void

    private let generation: UInt64
    private let targetFormat: AVAudioFormat
    private let onAudioBuffer: SystemAudioCaptureManager.AudioBufferHandler
    private let onStopped: StopHandler
    private let sampleAdmission = SystemAudioSampleAdmission()
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var lastFormatDescription: CMFormatDescription?

    init(
        generation: UInt64,
        targetFormat: AVAudioFormat,
        onAudioBuffer: @escaping SystemAudioCaptureManager.AudioBufferHandler,
        onStopped: @escaping StopHandler
    ) {
        self.generation = generation
        self.targetFormat = targetFormat
        self.onAudioBuffer = onAudioBuffer
        self.onStopped = onStopped
    }

    func deactivate() {
        sampleAdmission.deactivate()
    }

    /// Called only by the serial sample-handler queue after all earlier callbacks drained.
    func finishDeactivationOnAudioQueue() {
        sourceFormat = nil
        converter = nil
        lastFormatDescription = nil
    }

    func stream(
        _: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        sampleAdmission.performIfAccepting {
            guard let outputBuffer = convertedBuffer(from: sampleBuffer) else { return }
            onAudioBuffer(outputBuffer)
        }
    }

    func stream(_: SCStream, didStopWithError error: Error) {
        deactivate()
        onStopped(generation, error)
    }

    private func convertedBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = sampleBuffer.formatDescription else { return nil }

        if let lastFormatDescription {
            if !CMFormatDescriptionEqual(formatDescription, otherFormatDescription: lastFormatDescription) {
                configureConversion(formatDescription: formatDescription)
            }
        } else {
            configureConversion(formatDescription: formatDescription)
        }
        guard let converter, let sourceFormat else { return nil }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(
                  pcmFormat: sourceFormat,
                  frameCapacity: frameCount
              ) else { return nil }
        inputBuffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return AudioConverter.convert(inputBuffer, to: targetFormat, using: converter)
    }

    private func configureConversion(formatDescription: CMFormatDescription) {
        lastFormatDescription = formatDescription
        guard let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let sourceFormat = AVAudioFormat(streamDescription: description) else {
            self.sourceFormat = nil
            converter = nil
            return
        }
        self.sourceFormat = sourceFormat
        converter = AudioConverter.makeConverter(from: sourceFormat, to: targetFormat)
        converter?.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
    }
}
