@preconcurrency import AVFoundation
import ScreenCaptureKit

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

/// ScreenCaptureKit を使用してシステム音声をキャプチャし、
/// 指定されたターゲットフォーマットに変換して AVAudioPCMBuffer で出力する。
final class SystemAudioCaptureManager: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var captureTargetFormat: AVAudioFormat?
    private let audioQueue = DispatchQueue(label: "com.dahlia.systemaudio", qos: .userInitiated)

    /// 変換済み AVAudioPCMBuffer のコールバック
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// ストリームが予期せず停止した場合のコールバック
    var onStreamStopped: ((Error?) -> Void)?

    /// 画面収録パーミッションを確認する。
    static func requestPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            return false
        }
    }

    /// システム音声キャプチャを開始する。
    func startCapture(targetFormat: AVAudioFormat) async throws {
        self.captureTargetFormat = targetFormat

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw SystemAudioCaptureError.screenRecordingPermissionDenied
        }

        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayFound
        }

        let bundleID = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        // ビデオオーバーヘッドを最小化
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        config.excludesCurrentProcessAudio = true

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await newStream.startCapture()
        self.stream = newStream
    }

    /// キャプチャを停止する。
    func stopCapture() {
        guard let stream = self.stream else { return }
        self.stream = nil
        Task {
            try? await stream.stopCapture()
        }
        clearCaptureState()
    }

    /// capture停止の完了を待つ。セッションcontrollerの停止順序を保証するadapterから利用する。
    func stopCaptureAndWait() async throws {
        guard let stream = self.stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            clearCaptureState()
            throw error
        }
        clearCaptureState()
    }

    // MARK: - Private

    private var lastFormatDescription: CMFormatDescription?

    private func clearCaptureState() {
        converter = nil
        sourceFormat = nil
        captureTargetFormat = nil
        lastFormatDescription = nil
    }

    private func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let targetFormat = captureTargetFormat else { return }
        guard let formatDesc = sampleBuffer.formatDescription else { return }

        if lastFormatDescription == nil || !CMFormatDescriptionEqual(formatDesc, otherFormatDescription: lastFormatDescription!) {
            lastFormatDescription = formatDesc
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
            guard let newFormat = AVAudioFormat(streamDescription: asbd) else { return }
            sourceFormat = newFormat
            converter = AudioConverter.makeConverter(from: newFormat, to: targetFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        }
        guard let converter, let sourceFormat else { return }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0 else { return }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else { return }
        inputBuffer.frameLength = frameCount

        let status1 = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard status1 == noErr else { return }

        guard let outputBuffer = AudioConverter.convert(inputBuffer, to: targetFormat, using: converter) else { return }
        onAudioBuffer?(outputBuffer)
    }
}

// MARK: - SCStreamOutput

extension SystemAudioCaptureManager: SCStreamOutput {
    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        processAudioSampleBuffer(sampleBuffer)
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioCaptureManager: SCStreamDelegate {
    func stream(_: SCStream, didStopWithError error: Error) {
        self.stream = nil
        converter = nil
        sourceFormat = nil
        captureTargetFormat = nil
        lastFormatDescription = nil
        onStreamStopped?(error)
    }
}
