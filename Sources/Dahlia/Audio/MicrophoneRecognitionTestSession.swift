@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import os

actor MicrophoneRecognitionTestSession {
    typealias EventHandler = @MainActor @Sendable (MicrophoneRecognitionTestEvent) -> Void

    private static let logger = Logger(subsystem: "com.dahlia", category: "MicrophoneRecognitionTest")
    private static let registry = MicrophoneRecognitionTestRegistry()

    private var manager: AudioCaptureManager?
    private var service: SpeechTranscriberService?
    private var bridge: AudioBufferBridge?
    private var eventHandler: EventHandler?
    private var startGeneration = 0

    static func stopActiveSession() async {
        await registry.stopActiveSession()
    }

    func start(
        deviceID: AudioDeviceID?,
        locale: Locale,
        onEvent: @escaping EventHandler
    ) async throws -> AudioCaptureStartInfo {
        guard manager == nil else {
            throw AudioCaptureError.microphoneDeviceUnavailable
        }
        startGeneration &+= 1
        let generation = startGeneration
        await Self.registry.activate(self)

        do {
            guard await AudioCaptureManager.requestMicrophonePermission() else {
                throw AudioCaptureError.microphonePermissionDenied
            }
            try ensureCurrentStart(generation)

            let (service, bridge, targetFormat) = try await prepareRecognition(locale: locale, onEvent: onEvent)
            guard generation == startGeneration else {
                bridge.finish()
                await service.cancel()
                throw CancellationError()
            }
            let manager = makeManager(targetFormat: targetFormat, bridge: bridge, onEvent: onEvent)
            manager.onUnexpectedStop = { [weak self] _ in
                Task {
                    await self?.captureStoppedUnexpectedly()
                }
            }

            do {
                let startInfo = try manager.startCapture(
                    targetFormat: targetFormat,
                    selectedDeviceID: deviceID
                )
                self.manager = manager
                self.service = service
                self.bridge = bridge
                eventHandler = onEvent
                return startInfo
            } catch {
                bridge.finish()
                await service.cancel()
                throw error
            }
        } catch {
            await Self.registry.deactivate(self)
            throw error
        }
    }

    private func prepareRecognition(
        locale: Locale,
        onEvent: @escaping EventHandler
    ) async throws -> (SpeechTranscriberService, AudioBufferBridge, AVAudioFormat) {
        let service = SpeechTranscriberService(locale: locale, speakerLabel: RecordingAudioSource.microphone.speakerLabel)
        try await service.prepare()
        guard let targetFormat = await service.targetAudioFormat() else {
            throw AudioCaptureError.converterCreationFailed
        }

        let bridge = try AudioBufferBridge(sourceFormat: targetFormat, analyzerFormat: targetFormat)
        try await service.startStreaming(
            bridge: bridge,
            recordingStartTime: .now,
            recordingSessionId: .v7()
        ) { event in
            Self.forward(event, to: onEvent)
        }
        return (service, bridge, targetFormat)
    }

    private func makeManager(
        targetFormat: AVAudioFormat,
        bridge: AudioBufferBridge,
        onEvent: @escaping EventHandler
    ) -> AudioCaptureManager {
        let manager = AudioCaptureManager()
        let frameOffset = OSAllocatedUnfairLock(initialState: Int64(0))
        let bufferCount = OSAllocatedUnfairLock(initialState: 0)
        let timescale = CMTimeScale(targetFormat.sampleRate.rounded())
        manager.onAudioBuffer = { buffer in
            let frameLength = Int64(buffer.frameLength)
            let startFrame = frameOffset.withLock { offset in
                let startFrame = offset
                offset += frameLength
                return startFrame
            }
            let count = bufferCount.withLock { count in
                count += 1
                return count
            }
            let chunk = CapturedAudioChunk(
                source: .microphone,
                buffer: buffer,
                sessionRelativeStartTime: CMTime(value: startFrame, timescale: timescale)
            )
            if !bridge.append(chunk) {
                Self.logger.error("Speech analyzer rejected microphone buffer \(count)")
            }
            let level = AudioLevelCalculator.normalizedLevel(in: buffer)
            Task { @MainActor in
                onEvent(.inputLevel(level, bufferCount: count))
            }
        }
        manager.onInputLevels = { levels in
            Task { @MainActor in
                onEvent(.inputChannelLevels(levels))
            }
        }
        return manager
    }

    @MainActor
    private static func forward(_ event: TranscriptionEvent, to onEvent: EventHandler) {
        switch event {
        case let .preview(segment):
            onEvent(.transcript(segment.text, isFinal: false))
        case let .finalized(segment):
            onEvent(.transcript(segment.text, isFinal: true))
        case let .failure(_, _, _, message):
            onEvent(.failure(message))
        case .clearPreview, .translation:
            break
        }
    }

    func stop() async {
        startGeneration &+= 1
        let manager = manager
        let bridge = bridge
        let service = service
        let eventHandler = eventHandler
        clear()

        manager?.stopCapture()
        bridge?.finish()
        do {
            try await service?.stopStreaming()
        } catch {
            await eventHandler?(.failure(error.localizedDescription))
        }
        await service?.reset()
        await Self.registry.deactivate(self)
    }

    private func captureStoppedUnexpectedly() async {
        await eventHandler?(.captureStopped)
    }

    private func clear() {
        manager = nil
        service = nil
        bridge = nil
        eventHandler = nil
    }

    private func ensureCurrentStart(_ generation: Int) throws {
        guard generation == startGeneration else { throw CancellationError() }
    }
}

private actor MicrophoneRecognitionTestRegistry {
    private var activeSession: MicrophoneRecognitionTestSession?

    func activate(_ session: MicrophoneRecognitionTestSession) async {
        guard activeSession !== session else { return }
        let previousSession = activeSession
        activeSession = session
        await previousSession?.stop()
    }

    func deactivate(_ session: MicrophoneRecognitionTestSession) {
        if activeSession === session {
            activeSession = nil
        }
    }

    func stopActiveSession() async {
        let session = activeSession
        activeSession = nil
        await session?.stop()
    }
}
