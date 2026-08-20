import CoreGraphics
import DahliaRuntimeSupport
import Foundation
import GRDB
import os
@preconcurrency import ScreenCaptureKit

enum ScreenshotError: LocalizedError {
    case encodingFailed
    case displayUnavailable
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            L10n.screenshotEncodingFailed
        case .displayUnavailable:
            L10n.screenshotDisplayUnavailable
        case .sourceUnavailable:
            L10n.screenshotSourceUnavailable
        }
    }
}

struct AutomaticScreenshotCaptureRequest: Sendable {
    let source: ScreenshotCaptureSource
    var intervalSeconds: Int
    var changeThresholdRatio: Double
    let meetingID: UUID
    let sessionID: UUID?
    let dbQueue: DatabaseQueue
    let onPersisted: @MainActor @Sendable (MeetingScreenshotRecord) -> Void
    let onFailure: @MainActor @Sendable (Error) -> Void
}

protocol AutomaticScreenshotCapturing: Sendable {
    func start(_ request: AutomaticScreenshotCaptureRequest) async
    func updateSettings(intervalSeconds: Int, changeThresholdRatio: Double) async
    func stop() async
}

/// Serializes ordinary setting changes while allowing stop to invalidate and bypass
/// a slow ScreenCaptureKit capture operation.
@MainActor
final class AutomaticScreenshotCaptureControl {
    private let capture: any AutomaticScreenshotCapturing
    private var tailTask: Task<Void, Never>?
    private var stopGeneration: UInt64 = 0

    init(capture: any AutomaticScreenshotCapturing) {
        self.capture = capture
    }

    @discardableResult
    func enqueue(
        _ operation: @escaping @Sendable (any AutomaticScreenshotCapturing) async -> Void
    ) -> Task<Void, Never> {
        let operationGeneration = stopGeneration
        let previousTask = tailTask
        let capture = capture
        let task = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled,
                  let self,
                  self.stopGeneration == operationGeneration else { return }
            await operation(capture)
        }
        tailTask = task
        return task
    }

    @discardableResult
    func stop() -> Task<Void, Never> {
        stopGeneration &+= 1
        tailTask?.cancel()
        let capture = capture
        let task = Task {
            await capture.stop()
        }
        tailTask = task
        return task
    }
}

struct AutomaticScreenshotCaptureLifecycle {
    private(set) var generation: UInt64 = 0
    private(set) var isActive = false

    mutating func beginReplacement() -> UInt64 {
        generation &+= 1
        isActive = true
        return generation
    }

    mutating func stop() {
        generation &+= 1
        isActive = false
    }

    func accepts(generation: UInt64) -> Bool {
        isActive && self.generation == generation
    }
}

private enum ScreenshotCaptureMetrics {
    static let signposter = OSSignposter(subsystem: "com.dahlia", category: "AutomaticScreenshot")

    static func recordSlowStage(
        _ stage: ErrorReportingService.AutomaticScreenshotStage,
        startedAt: ContinuousClock.Instant
    ) {
        let components = startedAt.duration(to: .now).components
        let milliseconds = Int(clamping: components.seconds * 1000)
            + Int(clamping: components.attoseconds / 1_000_000_000_000_000)
        ErrorReportingService.recordSlowAutomaticScreenshotStage(
            stage,
            durationMilliseconds: milliseconds
        )
    }
}

struct AutomaticScreenshotCaptureOutput: Sendable {
    let image: CGImage
    let capturedAt: Date
}

private struct EncodedScreenshotFrame: Sendable {
    let data: Data
    let mimeType: String
}

private actor AutomaticScreenshotFrameProcessor {
    func fingerprint(for image: CGImage) -> ScreenshotFingerprint? {
        guard !Task.isCancelled else { return nil }
        let startedAt = ContinuousClock.now
        let state = ScreenshotCaptureMetrics.signposter.beginInterval("Fingerprint")
        let fingerprint = ScreenshotChangeDetector.fingerprint(for: image)
        ScreenshotCaptureMetrics.signposter.endInterval("Fingerprint", state)
        ScreenshotCaptureMetrics.recordSlowStage(.fingerprint, startedAt: startedAt)
        guard !Task.isCancelled, let fingerprint else { return nil }
        return fingerprint
    }

    func encode(_ image: CGImage) -> EncodedScreenshotFrame? {
        guard !Task.isCancelled else { return nil }
        let startedAt = ContinuousClock.now
        let state = ScreenshotCaptureMetrics.signposter.beginInterval("Encode")
        let data = ImageEncoder.encode(image, quality: 0.70)
        let mimeType = data.flatMap { ImageEncoder.mimeType(for: $0) }
        ScreenshotCaptureMetrics.signposter.endInterval("Encode", state)
        ScreenshotCaptureMetrics.recordSlowStage(.encoding, startedAt: startedAt)
        guard !Task.isCancelled, let data, let mimeType else { return nil }
        return EncodedScreenshotFrame(data: data, mimeType: mimeType)
    }
}

/// Periodically takes one-shot screenshots without holding a display stream open
/// while another app starts or runs screen sharing.
actor AutomaticScreenshotCaptureService: AutomaticScreenshotCapturing {
    typealias CaptureImage = @Sendable (ScreenshotCaptureSource) async throws -> AutomaticScreenshotCaptureOutput
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private var lifecycle = AutomaticScreenshotCaptureLifecycle()
    private let frameProcessor = AutomaticScreenshotFrameProcessor()
    private let captureImage: CaptureImage
    private let sleep: Sleep
    private var desiredRequest: AutomaticScreenshotCaptureRequest?
    private var captureTask: Task<Void, Never>?
    private var lastSavedFingerprint: ScreenshotFingerprint?

    init() {
        self.init(
            captureImage: Self.captureImage,
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    init(
        captureImage: @escaping CaptureImage,
        sleep: @escaping Sleep
    ) {
        self.captureImage = captureImage
        self.sleep = sleep
    }

    func start(_ request: AutomaticScreenshotCaptureRequest) {
        desiredRequest = Self.normalized(request)
        lastSavedFingerprint = nil
        restartCaptureLoop(captureImmediately: true)
    }

    func updateSettings(intervalSeconds: Int, changeThresholdRatio: Double) {
        guard var request = desiredRequest else { return }
        request.intervalSeconds = intervalSeconds
        request.changeThresholdRatio = changeThresholdRatio
        desiredRequest = Self.normalized(request)
        restartCaptureLoop(captureImmediately: false)
    }

    func stop() {
        desiredRequest = nil
        lifecycle.stop()
        captureTask?.cancel()
    }

    private func restartCaptureLoop(captureImmediately: Bool) {
        let previousTask = captureTask
        previousTask?.cancel()
        let generation = lifecycle.beginReplacement()
        captureTask = Task(priority: .utility) { [weak self] in
            if captureImmediately {
                await previousTask?.value
            } else {
                async let intervalElapsed = self?.sleepUntilNextCapture(generation: generation)
                await previousTask?.value
                guard await intervalElapsed == true else { return }
            }
            guard !Task.isCancelled else { return }
            await self?.runCaptureLoop(
                generation: generation
            )
        }
    }

    private func runCaptureLoop(generation: UInt64) async {
        while lifecycle.accepts(generation: generation),
              let request = desiredRequest {
            async let intervalElapsed: Void = sleep(.seconds(request.intervalSeconds))
            await captureAndPersist(generation: generation)
            do {
                try await intervalElapsed
            } catch {
                return
            }
        }
    }

    private func sleepUntilNextCapture(generation: UInt64) async -> Bool {
        guard lifecycle.accepts(generation: generation),
              let request = desiredRequest else { return false }
        do {
            try await sleep(.seconds(request.intervalSeconds))
        } catch {
            return false
        }
        return lifecycle.accepts(generation: generation)
    }

    private func captureAndPersist(generation: UInt64) async {
        guard lifecycle.accepts(generation: generation),
              let request = desiredRequest else { return }
        do {
            let screenshot = try await captureImage(request.source)
            guard !Task.isCancelled,
                  lifecycle.accepts(generation: generation) else { return }
            await process(screenshot, request: request, generation: generation)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  lifecycle.accepts(generation: generation) else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                request.onFailure(error)
            }
        }
    }

    private func process(
        _ screenshot: AutomaticScreenshotCaptureOutput,
        request: AutomaticScreenshotCaptureRequest,
        generation: UInt64
    ) async {
        let fingerprint = await frameProcessor.fingerprint(for: screenshot.image)
        guard let fingerprint,
              !Task.isCancelled,
              lifecycle.accepts(generation: generation) else { return }
        guard shouldSave(
            fingerprint,
            changeThresholdRatio: request.changeThresholdRatio
        ) else { return }

        guard let encoded = await frameProcessor.encode(screenshot.image) else {
            guard !Task.isCancelled,
                  lifecycle.accepts(generation: generation) else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                request.onFailure(ScreenshotError.encodingFailed)
            }
            return
        }
        guard !Task.isCancelled,
              lifecycle.accepts(generation: generation),
              shouldSave(
                  fingerprint,
                  changeThresholdRatio: request.changeThresholdRatio
              ) else { return }

        let record = Self.makeRecord(
            capturedAt: screenshot.capturedAt,
            meetingID: request.meetingID,
            sessionID: request.sessionID,
            encodedData: encoded.data,
            mimeType: encoded.mimeType
        )
        let persistenceStartedAt = ContinuousClock.now
        let persistenceState = ScreenshotCaptureMetrics.signposter.beginInterval("Persist")
        do {
            try await request.dbQueue.write { db in
                try record.insert(db)
            }
        } catch {
            ScreenshotCaptureMetrics.signposter.endInterval("Persist", persistenceState)
            ScreenshotCaptureMetrics.recordSlowStage(.persistence, startedAt: persistenceStartedAt)
            guard !Task.isCancelled,
                  lifecycle.accepts(generation: generation) else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                request.onFailure(error)
            }
            return
        }
        ScreenshotCaptureMetrics.signposter.endInterval("Persist", persistenceState)
        ScreenshotCaptureMetrics.recordSlowStage(.persistence, startedAt: persistenceStartedAt)

        guard !Task.isCancelled,
              lifecycle.accepts(generation: generation) else { return }
        lastSavedFingerprint = fingerprint
        await MainActor.run {
            guard !Task.isCancelled else { return }
            request.onPersisted(record)
        }
    }

    private func shouldSave(
        _ fingerprint: ScreenshotFingerprint,
        changeThresholdRatio: Double
    ) -> Bool {
        guard let lastSavedFingerprint else { return true }
        return ScreenshotChangeDetector.isSignificantlyDifferent(
            lastSavedFingerprint,
            fingerprint,
            changedPixelRatioThreshold: changeThresholdRatio
        )
    }
}

extension AutomaticScreenshotCaptureService {
    private static func normalized(_ request: AutomaticScreenshotCaptureRequest) -> AutomaticScreenshotCaptureRequest {
        var request = request
        request.intervalSeconds = max(1, request.intervalSeconds)
        if !request.changeThresholdRatio.isFinite {
            request.changeThresholdRatio = 0.20
        } else {
            request.changeThresholdRatio = min(max(request.changeThresholdRatio, 0.01), 1)
        }
        return request
    }

    static func makeRecord(
        capturedAt: Date,
        meetingID: UUID,
        sessionID: UUID?,
        encodedData: Data,
        mimeType: String
    ) -> MeetingScreenshotRecord {
        MeetingScreenshotRecord(
            id: UUID.v7(),
            meetingId: meetingID,
            sessionId: sessionID,
            capturedAt: capturedAt,
            imageData: encodedData,
            mimeType: mimeType
        )
    }

    private static func captureImage(source: ScreenshotCaptureSource) async throws -> AutomaticScreenshotCaptureOutput {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        let filter = try contentFilter(source: source, content: content)
        let configuration = screenshotConfiguration(filter: filter)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return AutomaticScreenshotCaptureOutput(image: image, capturedAt: .now)
    }

    private static func contentFilter(
        source: ScreenshotCaptureSource,
        content: SCShareableContent
    ) throws -> SCContentFilter {
        switch source {
        case .none:
            throw ScreenshotError.sourceUnavailable
        case .entireDesktop:
            guard let display = content.displays.first else {
                throw ScreenshotError.displayUnavailable
            }
            return SCContentFilter(display: display, excludingWindows: [])
        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenshotError.sourceUnavailable
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    private static func screenshotConfiguration(filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((filter.contentRect.width * Double(filter.pointPixelScale)).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * Double(filter.pointPixelScale)).rounded()))
        configuration.captureResolution = .best
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return configuration
    }
}
