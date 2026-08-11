import Foundation

/// SpeechTranscriberServiceとAudioBufferBridgeを同一ライフサイクルで扱うadapter。
actor DefaultProgressiveRecognitionSession: ProgressiveRecognitionSession {
    nonisolated let pipelineID: UUID
    nonisolated let liveConsumer: AudioFrameRouter.LiveConsumer

    private let service: SpeechTranscriberService
    private let bridge: AudioBufferBridge

    init(service: SpeechTranscriberService, bridge: AudioBufferBridge) {
        pipelineID = service.pipelineID
        liveConsumer = { [bridge] chunk in
            bridge.append(chunk)
        }
        self.service = service
        self.bridge = bridge
    }

    func start(
        recordingStartTime: Date,
        recordingSessionId: UUID,
        onEvent: @escaping ProgressiveTranscriptionEventHandler
    ) async throws {
        try await service.startStreaming(
            bridge: bridge,
            recordingStartTime: recordingStartTime,
            recordingSessionId: recordingSessionId,
            onEvent: onEvent
        )
    }

    func finish() async throws {
        bridge.finish()
        try await service.stopStreaming()
    }

    func cancel() async {
        bridge.finish()
        await service.cancel()
    }
}
