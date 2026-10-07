@preconcurrency import CoreMedia
import CoreVideo
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
    var usesAdaptiveInterval: Bool
    var changeThresholdRatio: Double
    var detectsChangesInSharedContentOnly: Bool
    var cropsToSharedContent: Bool
    let meetingID: UUID
    let sessionID: UUID?
    let dbQueue: DatabaseQueue
    let onPersisted: @MainActor @Sendable (MeetingScreenshotRecord) -> Void
    let onFailure: @MainActor @Sendable (Error) -> Void
}

protocol AutomaticScreenshotCapturing: Sendable {
    func start(_ request: AutomaticScreenshotCaptureRequest) async
    func updateSettings(
        intervalSeconds: Int,
        usesAdaptiveInterval: Bool,
        changeThresholdRatio: Double,
        detectsChangesInSharedContentOnly: Bool,
        cropsToSharedContent: Bool
    ) async
    func stop() async
}

/// Serializes ordinary setting changes while allowing stop to invalidate and bypass
/// a slow ScreenCaptureKit start operation.
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

struct AutomaticScreenshotCaptureAttempt: Equatable, Sendable {
    let generation: UInt64
    let id: UInt64
}

enum AutomaticScreenshotCaptureOutcome: Equatable, Sendable {
    case saved
    case skipped
    case discarded
    case failed
}

struct AutomaticScreenshotCaptureLifecycle {
    private(set) var generation: UInt64 = 0
    private(set) var isActive = false
    private(set) var activeAttempt: AutomaticScreenshotCaptureAttempt?
    private var nextAttemptID: UInt64 = 0
    private var isCompletionInProgress = false

    mutating func begin() -> UInt64? {
        guard !isActive, activeAttempt == nil else { return nil }
        generation &+= 1
        isActive = true
        isCompletionInProgress = false
        return generation
    }

    mutating func beginReplacement() -> UInt64 {
        generation &+= 1
        isActive = true
        activeAttempt = nil
        isCompletionInProgress = false
        return generation
    }

    mutating func stop() {
        generation &+= 1
        isActive = false
        activeAttempt = nil
        isCompletionInProgress = false
    }

    func accepts(generation: UInt64) -> Bool {
        isActive && self.generation == generation
    }

    mutating func beginAttempt(generation: UInt64) -> AutomaticScreenshotCaptureAttempt? {
        guard accepts(generation: generation), activeAttempt == nil else { return nil }
        nextAttemptID &+= 1
        let attempt = AutomaticScreenshotCaptureAttempt(generation: generation, id: nextAttemptID)
        activeAttempt = attempt
        isCompletionInProgress = false
        return attempt
    }

    func accepts(attempt: AutomaticScreenshotCaptureAttempt) -> Bool {
        accepts(generation: attempt.generation)
            && activeAttempt == attempt
            && !isCompletionInProgress
    }

    mutating func claimCompletion(attempt: AutomaticScreenshotCaptureAttempt) -> Bool {
        guard accepts(attempt: attempt) else { return false }
        isCompletionInProgress = true
        return true
    }

    mutating func finishAttempt(_ attempt: AutomaticScreenshotCaptureAttempt) {
        guard activeAttempt == attempt else { return }
        activeAttempt = nil
        isCompletionInProgress = false
    }
}

struct CopiedScreenshotFrame: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: Data

    func makeImage() -> CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

struct AutomaticScreenshotFrameMailbox: Sendable {
    let stream: AsyncStream<CopiedScreenshotFrame>
    private let continuation: AsyncStream<CopiedScreenshotFrame>.Continuation

    init() {
        let pair = AsyncStream.makeStream(
            of: CopiedScreenshotFrame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ frame: CopiedScreenshotFrame) {
        continuation.yield(frame)
    }

    func finish() {
        continuation.finish()
    }
}

struct AutomaticScreenshotProcessingState {
    struct Operation {
        let id: UInt64
        let attempt: AutomaticScreenshotCaptureAttempt
        let task: Task<Void, Never>
    }

    private(set) var operation: Operation?
    private var nextOperationID: UInt64 = 0

    var isProcessing: Bool {
        operation != nil
    }

    mutating func begin(
        attempt: AutomaticScreenshotCaptureAttempt,
        task: (UInt64) -> Task<Void, Never>
    ) {
        precondition(operation == nil)
        nextOperationID &+= 1
        let operationID = nextOperationID
        operation = Operation(
            id: operationID,
            attempt: attempt,
            task: task(operationID)
        )
    }

    mutating func complete(
        operationID: UInt64,
        attempt: AutomaticScreenshotCaptureAttempt
    ) -> Bool {
        guard let operation,
              operation.id == operationID,
              operation.attempt == attempt else { return false }
        self.operation = nil
        return true
    }

    mutating func take(
        matching attempt: AutomaticScreenshotCaptureAttempt? = nil
    ) -> Operation? {
        guard let operation,
              attempt == nil || operation.attempt == attempt else { return nil }
        self.operation = nil
        return operation
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

private struct EncodedScreenshotFrame: Sendable {
    let data: Data
    let mimeType: String
}

struct PreparedScreenshotFrame: Sendable {
    let imageToEncode: CGImage
    let fingerprint: ScreenshotFingerprint
    /// Whether the fingerprint covers a detected shared-content crop instead of the whole screen.
    let fingerprintsSharedContent: Bool
    /// The whole captured screen, compared with recently saved screens.
    let screenFingerprint: ScreenshotFingerprint

    /// The settle tracker decides when to capture from the whole screen. A detected crop is also compared with the
    /// last saved crop, so changes outside it, such as camera tiles, are not saved.
    func shouldSave(
        after lastSavedFingerprint: ScreenshotFingerprint?,
        changeThresholdRatio: Double
    ) -> Bool {
        guard fingerprintsSharedContent, let lastSavedFingerprint else { return true }
        return ScreenshotChangeDetector.isSignificantlyDifferent(
            lastSavedFingerprint,
            fingerprint,
            changedPixelRatioThreshold: changeThresholdRatio
        )
    }
}

actor AutomaticScreenshotFrameProcessor {
    private static let maximumSharedContentEdgeDriftRatio: CGFloat = 0.02

    private let detectSharedContentRegion: @Sendable (CGImage) async -> CGRect?
    private var stableSharedContentRegion: CGRect?
    private var stableSharedContentImageSize: CGSize?
    private var didMissPreviousSharedContentDetection = false
    private var sharedContentRegionGeneration: UInt64 = 0

    init(
        detectSharedContentRegion: @escaping @Sendable (CGImage) async -> CGRect? = {
            await ScreenshotSharedContentRegionDetector.region(in: $0)
        }
    ) {
        self.detectSharedContentRegion = detectSharedContentRegion
    }

    func prepare(
        _ image: CGImage,
        detectsChangesInSharedContentOnly: Bool,
        cropsToSharedContent: Bool
    ) async -> PreparedScreenshotFrame? {
        guard !Task.isCancelled else { return nil }
        let sharedContentImage: CGImage?
        if detectsChangesInSharedContentOnly || cropsToSharedContent {
            let generation = sharedContentRegionGeneration
            let state = ScreenshotCaptureMetrics.signposter.beginInterval("SharedContentRegion")
            let detectedRegion = await detectSharedContentRegion(image)
            ScreenshotCaptureMetrics.signposter.endInterval("SharedContentRegion", state)
            guard !Task.isCancelled,
                  generation == sharedContentRegionGeneration else { return nil }
            let region = stabilizedSharedContentRegion(
                detectedRegion,
                imageSize: CGSize(width: image.width, height: image.height)
            )
            sharedContentImage = region.flatMap { image.cropping(to: $0) }
        } else {
            resetSharedContentRegion()
            sharedContentImage = nil
        }
        guard !Task.isCancelled else { return nil }

        let selectedImages = Self.selectedImages(
            fullImage: image,
            sharedContentImage: sharedContentImage,
            detectsChangesInSharedContentOnly: detectsChangesInSharedContentOnly,
            cropsToSharedContent: cropsToSharedContent
        )
        let fingerprintsSharedContent = detectsChangesInSharedContentOnly && sharedContentImage != nil
        let startedAt = ContinuousClock.now
        let state = ScreenshotCaptureMetrics.signposter.beginInterval("Fingerprint")
        let fingerprint = ScreenshotChangeDetector.fingerprint(for: selectedImages.fingerprint)
        let screenFingerprint = fingerprintsSharedContent ? ScreenshotChangeDetector.fingerprint(for: image) : fingerprint
        ScreenshotCaptureMetrics.signposter.endInterval("Fingerprint", state)
        ScreenshotCaptureMetrics.recordSlowStage(.fingerprint, startedAt: startedAt)
        guard !Task.isCancelled, let fingerprint, let screenFingerprint else { return nil }
        return PreparedScreenshotFrame(
            imageToEncode: selectedImages.encoding,
            fingerprint: fingerprint,
            fingerprintsSharedContent: fingerprintsSharedContent,
            screenFingerprint: screenFingerprint
        )
    }

    func resetSharedContentRegion() {
        sharedContentRegionGeneration &+= 1
        stableSharedContentRegion = nil
        stableSharedContentImageSize = nil
        didMissPreviousSharedContentDetection = false
    }

    func stabilizedSharedContentRegion(
        _ detectedRegion: CGRect?,
        imageSize: CGSize
    ) -> CGRect? {
        guard let detectedRegion else {
            guard stableSharedContentImageSize == imageSize,
                  !didMissPreviousSharedContentDetection,
                  let stableSharedContentRegion else {
                resetSharedContentRegion()
                return nil
            }
            didMissPreviousSharedContentDetection = true
            return stableSharedContentRegion
        }

        let region: CGRect = if stableSharedContentImageSize == imageSize,
                                let stableSharedContentRegion,
                                Self.isNearby(detectedRegion, stableSharedContentRegion, imageSize: imageSize) {
            stableSharedContentRegion
        } else {
            detectedRegion
        }
        stableSharedContentRegion = region
        stableSharedContentImageSize = imageSize
        didMissPreviousSharedContentDetection = false
        return region
    }

    private static func isNearby(
        _ lhs: CGRect,
        _ rhs: CGRect,
        imageSize: CGSize
    ) -> Bool {
        let horizontalTolerance = imageSize.width * maximumSharedContentEdgeDriftRatio
        let verticalTolerance = imageSize.height * maximumSharedContentEdgeDriftRatio
        return abs(lhs.minX - rhs.minX) <= horizontalTolerance
            && abs(lhs.maxX - rhs.maxX) <= horizontalTolerance
            && abs(lhs.minY - rhs.minY) <= verticalTolerance
            && abs(lhs.maxY - rhs.maxY) <= verticalTolerance
    }

    static func selectedImages(
        fullImage: CGImage,
        sharedContentImage: CGImage?,
        detectsChangesInSharedContentOnly: Bool,
        cropsToSharedContent: Bool
    ) -> (fingerprint: CGImage, encoding: CGImage) {
        let detectedOrFullImage = sharedContentImage ?? fullImage
        return (
            fingerprint: detectsChangesInSharedContentOnly ? detectedOrFullImage : fullImage,
            encoding: cropsToSharedContent ? detectedOrFullImage : fullImage
        )
    }

    /// Runs off this actor so that encoding a saved frame never delays preparing the next capture.
    @concurrent fileprivate nonisolated static func encode(_ image: CGImage) async -> EncodedScreenshotFrame? {
        guard !Task.isCancelled else { return nil }
        let startedAt = ContinuousClock.now
        let state = ScreenshotCaptureMetrics.signposter.beginInterval("Encode")
        let data = ImageEncoder.encode(downscaledForSaving(image))
        let mimeType = data.flatMap { ImageEncoder.mimeType(for: $0) }
        ScreenshotCaptureMetrics.signposter.endInterval("Encode", state)
        ScreenshotCaptureMetrics.recordSlowStage(.encoding, startedAt: startedAt)
        guard !Task.isCancelled, let data, let mimeType else { return nil }
        return EncodedScreenshotFrame(data: data, mimeType: mimeType)
    }

    /// Scales the saved image, after any shared-content crop, to `ImageEncoder.screenshotMaximumLongEdge`.
    static func downscaledForSaving(_ image: CGImage) -> CGImage {
        let longEdge = max(image.width, image.height)
        guard longEdge > ImageEncoder.screenshotMaximumLongEdge else { return image }
        let scale = Double(ImageEncoder.screenshotMaximumLongEdge) / Double(longEdge)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

/// Watches a low-resolution ScreenCaptureKit stream for settled changes, or for changes at a fixed interval,
/// captures full-resolution screenshots only for those changes, and keeps image-sized work off MainActor.
/// Only capturing and deciding on a frame is exclusive; saved frames are encoded and persisted in capture order
/// behind it, so the next change can be captured while the previous one is still being saved.
actor AutomaticScreenshotCaptureService: AutomaticScreenshotCapturing {
    /// Each pending save holds a full-resolution image, so one may encode while one more waits behind it.
    private static let maximumPendingSaveCount = 2

    private struct ActiveCapture {
        let attempt: AutomaticScreenshotCaptureAttempt
        let stream: SCStream
        let filter: SCContentFilter
        let adapter: AutomaticScreenshotStreamAdapter
        let frameConsumerTask: Task<Void, Never>
    }

    private var lifecycle = AutomaticScreenshotCaptureLifecycle()
    private let frameProcessor = AutomaticScreenshotFrameProcessor()
    private let frameQueue = AutomaticScreenshotFrameQueue()
    private var desiredRequest: AutomaticScreenshotCaptureRequest?
    private var activeCapture: ActiveCapture?
    private var processingState = AutomaticScreenshotProcessingState()
    private var saveTask: Task<Void, Never>?
    private var pendingSaveCount = 0
    /// The last saved shared-content crop. A whole-screen fallback never becomes this baseline.
    private var lastSavedCropFingerprint: ScreenshotFingerprint?
    private var settleTracker = ScreenshotSettleTracker()
    private var settleCheckTask: Task<Void, Never>?
    private var failedCaptureRetryNotBefore: ContinuousClock.Instant?
    private var retryTask: Task<Void, Never>?

    func start(_ request: AutomaticScreenshotCaptureRequest) async {
        desiredRequest = Self.normalized(request)
        retryTask?.cancel()
        retryTask = nil
        let generation = lifecycle.beginReplacement()
        await stopCaptureAndProcessing()
        guard lifecycle.accepts(generation: generation) else { return }
        lastSavedCropFingerprint = nil
        settleTracker = ScreenshotSettleTracker()
        failedCaptureRetryNotBefore = nil
        await startStream(generation: generation)
    }

    func updateSettings(
        intervalSeconds: Int,
        usesAdaptiveInterval: Bool,
        changeThresholdRatio: Double,
        detectsChangesInSharedContentOnly: Bool,
        cropsToSharedContent: Bool
    ) async {
        guard var request = desiredRequest else { return }
        let detectionScopeChanged = request.detectsChangesInSharedContentOnly != detectsChangesInSharedContentOnly
        let sharedContentSettingsChanged = detectionScopeChanged || request.cropsToSharedContent != cropsToSharedContent
        request.intervalSeconds = intervalSeconds
        request.usesAdaptiveInterval = usesAdaptiveInterval
        request.changeThresholdRatio = changeThresholdRatio
        request.detectsChangesInSharedContentOnly = detectsChangesInSharedContentOnly
        request.cropsToSharedContent = cropsToSharedContent
        desiredRequest = Self.normalized(request)
        if detectionScopeChanged {
            lastSavedCropFingerprint = nil
        }
        if sharedContentSettingsChanged {
            await frameProcessor.resetSharedContentRegion()
        }
        // The pending timer and decision follow these settings, and an idle display may deliver no frame to apply them.
        if let attempt = activeCapture?.attempt {
            scheduleSettleCheck(after: .now, attempt: attempt)
            evaluateCapture(attempt: attempt)
        }
    }

    func stop() async {
        desiredRequest = nil
        retryTask?.cancel()
        retryTask = nil
        lifecycle.stop()
        await stopCaptureAndProcessing()
    }

    private func stopCaptureAndProcessing() async {
        settleCheckTask?.cancel()
        settleCheckTask = nil
        let processingOperation = processingState.take()
        processingOperation?.task.cancel()
        await stopActiveCapture()
        await processingOperation?.task.value
        // The lifecycle no longer accepts this generation, so no new save is queued and earlier queued saves
        // discard themselves; awaiting the tail drains them all.
        saveTask?.cancel()
        await saveTask?.value
        await frameProcessor.resetSharedContentRegion()
    }

    private func startStream(generation: UInt64) async {
        guard let request = desiredRequest,
              let attempt = lifecycle.beginAttempt(generation: generation) else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard lifecycle.accepts(attempt: attempt) else { return }
            let filter = try Self.contentFilter(source: request.source, content: content)
            let frameMailbox = AutomaticScreenshotFrameMailbox()
            let adapter = AutomaticScreenshotStreamAdapter(
                attempt: attempt,
                frameMailbox: frameMailbox,
                onStopped: { [weak self] attempt, error in
                    Task {
                        await self?.handleRuntimeFailure(error, attempt: attempt)
                    }
                }
            )
            let stream = SCStream(
                filter: filter,
                configuration: Self.detectionStreamConfiguration(filter: filter),
                delegate: adapter
            )
            try stream.addStreamOutput(
                adapter,
                type: .screen,
                sampleHandlerQueue: frameQueue.sampleHandlerQueue
            )
            guard lifecycle.accepts(attempt: attempt) else {
                adapter.deactivate()
                return
            }
            let frameConsumerTask = Task(priority: .utility) { [weak self] in
                for await frame in frameMailbox.stream {
                    guard !Task.isCancelled else { break }
                    await self?.receive(frame, attempt: attempt)
                }
            }
            activeCapture = ActiveCapture(
                attempt: attempt,
                stream: stream,
                filter: filter,
                adapter: adapter,
                frameConsumerTask: frameConsumerTask
            )
            try await stream.startCapture()
        } catch {
            await handleRuntimeFailure(error, attempt: attempt)
        }
    }

    private func stopActiveCapture() async {
        guard let activeCapture else { return }
        self.activeCapture = nil
        lifecycle.finishAttempt(activeCapture.attempt)
        await stopCaptureResources(activeCapture)
    }

    private func stopCaptureResources(_ capture: ActiveCapture) async {
        capture.adapter.deactivate()
        capture.frameConsumerTask.cancel()
        try? await capture.stream.stopCapture()
        await frameQueue.drain()
        await capture.frameConsumerTask.value
    }

    private func takeActiveCapture(matching attempt: AutomaticScreenshotCaptureAttempt) -> ActiveCapture? {
        guard let activeCapture, activeCapture.attempt == attempt else { return nil }
        self.activeCapture = nil
        activeCapture.adapter.deactivate()
        activeCapture.frameConsumerTask.cancel()
        return activeCapture
    }

    private func handleRuntimeFailure(
        _ error: Error,
        attempt: AutomaticScreenshotCaptureAttempt
    ) async {
        guard let request = desiredRequest,
              lifecycle.claimCompletion(attempt: attempt) else { return }
        let capture = takeActiveCapture(matching: attempt)
        let processingOperation = processingState.take(matching: attempt)
        processingOperation?.task.cancel()
        if let capture {
            await stopCaptureResources(capture)
        }
        await processingOperation?.task.value
        lifecycle.finishAttempt(attempt)
        guard lifecycle.accepts(generation: attempt.generation),
              desiredRequest != nil else { return }
        await request.onFailure(error)
        guard lifecycle.accepts(generation: attempt.generation),
              desiredRequest != nil else { return }
        ErrorReportingService.recordAutomaticScreenshotStreamRestart()
        scheduleRetry(
            generation: attempt.generation,
            intervalSeconds: request.intervalSeconds
        )
    }

    private func scheduleRetry(generation: UInt64, intervalSeconds: Int) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(1, intervalSeconds)))
            } catch {
                return
            }
            guard let self else { return }
            await self.retry(generation: generation)
        }
    }

    private func retry(generation: UInt64) async {
        guard lifecycle.accepts(generation: generation),
              lifecycle.activeAttempt == nil,
              desiredRequest != nil else { return }
        retryTask = nil
        await startStream(generation: generation)
    }

    private func receive(
        _ frame: CopiedScreenshotFrame,
        attempt: AutomaticScreenshotCaptureAttempt
    ) {
        guard lifecycle.accepts(attempt: attempt),
              let request = desiredRequest,
              let image = frame.makeImage(),
              let fingerprint = ScreenshotChangeDetector.fingerprint(for: image) else { return }
        let now = ContinuousClock.now
        settleTracker.ingest(fingerprint, at: now, changeThresholdRatio: request.changeThresholdRatio)
        scheduleSettleCheck(after: now, attempt: attempt)
        evaluateCapture(attempt: attempt)
    }

    private func scheduleSettleCheck(
        after now: ContinuousClock.Instant,
        attempt: AutomaticScreenshotCaptureAttempt
    ) {
        settleCheckTask?.cancel()
        settleCheckTask = nil
        guard let request = desiredRequest else { return }
        // ScreenCaptureKit can stop delivering frames while the display is idle, so a timer observes the settle
        // or the fixed interval, and the end of a failed-capture backoff.
        let checkDeadline = settleTracker.checkDeadline(
            after: now,
            interval: .seconds(request.intervalSeconds),
            isAdaptive: request.usesAdaptiveInterval
        )
        let retryDeadline = failedCaptureRetryNotBefore.flatMap { $0 > now ? $0 : nil }
        guard let deadline = [checkDeadline, retryDeadline].compactMap(\.self).max()
        else { return }
        settleCheckTask = Task(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return
            }
            await self?.settleCheckDidFire(attempt: attempt)
        }
    }

    /// An idle display may deliver no frame to schedule the next deadline, such as the interval that a gradual change
    /// waits for after an earlier settle deadline, so the timer schedules it before evaluating.
    private func settleCheckDidFire(attempt: AutomaticScreenshotCaptureAttempt) {
        scheduleSettleCheck(after: .now, attempt: attempt)
        evaluateCapture(attempt: attempt)
    }

    private func evaluateCapture(attempt: AutomaticScreenshotCaptureAttempt) {
        // A restarting stream already owns the attempt but has no capture yet; processing would only discard and
        // re-evaluate in a loop, so its first frame triggers the check instead.
        guard lifecycle.accepts(attempt: attempt),
              activeCapture?.attempt == attempt,
              !processingState.isProcessing,
              pendingSaveCount < Self.maximumPendingSaveCount,
              let request = desiredRequest else { return }
        let now = ContinuousClock.now
        if let failedCaptureRetryNotBefore {
            guard now >= failedCaptureRetryNotBefore else { return }
            self.failedCaptureRetryNotBefore = nil
        }
        guard settleTracker.shouldCapture(
            at: now,
            interval: .seconds(request.intervalSeconds),
            isAdaptive: request.usesAdaptiveInterval,
            changeThresholdRatio: request.changeThresholdRatio
        ) else { return }
        startProcessing(
            attempt: attempt,
            reference: settleTracker.captureReference(at: now, isAdaptive: request.usesAdaptiveInterval)
        )
    }

    private func startProcessing(
        attempt: AutomaticScreenshotCaptureAttempt,
        reference: ScreenshotSettleTracker.CaptureReference
    ) {
        processingState.begin(attempt: attempt) { [weak self] operationID in
            Task(priority: .utility) {
                guard let outcome = await self?.process(
                    attempt: attempt,
                    reference: reference
                ) else { return }
                await self?.finishProcessing(
                    operationID: operationID,
                    attempt: attempt,
                    outcome: outcome
                )
            }
        }
    }

    /// Captures and decides on one frame, then hands a saved frame to `enqueueSave`.
    private func process(
        attempt: AutomaticScreenshotCaptureAttempt,
        reference: ScreenshotSettleTracker.CaptureReference
    ) async -> AutomaticScreenshotCaptureOutcome {
        guard lifecycle.accepts(attempt: attempt),
              let request = desiredRequest,
              let activeCapture,
              activeCapture.attempt == attempt else { return .discarded }
        let capturedAt = Date.now
        let image: CGImage
        let captureState = ScreenshotCaptureMetrics.signposter.beginInterval("Capture")
        do {
            image = try await Self.captureScreenshot(filter: activeCapture.filter)
            ScreenshotCaptureMetrics.signposter.endInterval("Capture", captureState)
        } catch {
            ScreenshotCaptureMetrics.signposter.endInterval("Capture", captureState)
            guard !Task.isCancelled,
                  lifecycle.accepts(attempt: attempt) else { return .discarded }
            await request.onFailure(error)
            return .failed
        }
        let preparedFrame = await frameProcessor.prepare(
            image,
            detectsChangesInSharedContentOnly: request.detectsChangesInSharedContentOnly,
            cropsToSharedContent: request.cropsToSharedContent
        )
        // Only a capture its attempt still accepts may commit: a replacement start resets the tracker, and a stream
        // restart that took this operation leaves the change pending. Nothing suspends from here to the hand-off,
        // so the next evaluation always sees this decision.
        guard let preparedFrame,
              !Task.isCancelled,
              lifecycle.accepts(attempt: attempt),
              processingScopeMatches(request) else { return .discarded }

        settleTracker.commit(reference)
        // A screen shown again, such as a slide revisited after others, is saved only once.
        guard !settleTracker.matchesSavedScreen(
            preparedFrame.screenFingerprint,
            reference: reference,
            changeThresholdRatio: request.changeThresholdRatio
        ) else { return .skipped }
        guard preparedFrame.shouldSave(
            after: lastSavedCropFingerprint,
            changeThresholdRatio: request.changeThresholdRatio
        ) else { return .skipped }
        settleTracker.rememberSavedScreen(preparedFrame.screenFingerprint)
        if preparedFrame.fingerprintsSharedContent {
            lastSavedCropFingerprint = preparedFrame.fingerprint
        }
        enqueueSave(
            preparedFrame.imageToEncode,
            capturedAt: capturedAt,
            request: request,
            generation: attempt.generation
        )
        return .saved
    }

    private func finishProcessing(
        operationID: UInt64,
        attempt: AutomaticScreenshotCaptureAttempt,
        outcome: AutomaticScreenshotCaptureOutcome
    ) {
        if outcome == .failed {
            delayAfterFailure(generation: attempt.generation)
        }
        guard processingState.complete(
            operationID: operationID,
            attempt: attempt
        ) else { return }
        // Changes that settled while processing may have no frame or timer left to observe them.
        evaluateCapture(attempt: attempt)
    }

    /// Saves run in capture order and outlive a stream restart, because the captured image no longer needs the stream.
    private func enqueueSave(
        _ image: CGImage,
        capturedAt: Date,
        request: AutomaticScreenshotCaptureRequest,
        generation: UInt64
    ) {
        pendingSaveCount += 1
        let previousTask = saveTask
        saveTask = Task(priority: .utility) { [weak self] in
            await previousTask?.value
            guard let outcome = await self?.save(
                image,
                capturedAt: capturedAt,
                request: request,
                generation: generation
            ) else { return }
            await self?.finishSave(outcome: outcome, generation: generation)
        }
    }

    private func save(
        _ image: CGImage,
        capturedAt: Date,
        request: AutomaticScreenshotCaptureRequest,
        generation: UInt64
    ) async -> AutomaticScreenshotCaptureOutcome {
        guard !Task.isCancelled,
              lifecycle.accepts(generation: generation) else { return .discarded }
        guard let encoded = await AutomaticScreenshotFrameProcessor.encode(image) else {
            guard !Task.isCancelled,
                  lifecycle.accepts(generation: generation) else { return .discarded }
            await request.onFailure(ScreenshotError.encodingFailed)
            return .failed
        }
        guard !Task.isCancelled,
              lifecycle.accepts(generation: generation) else { return .discarded }

        let record = Self.makeRecord(
            capturedAt: capturedAt,
            meetingID: request.meetingID,
            sessionID: request.sessionID,
            encodedData: encoded.data,
            mimeType: encoded.mimeType
        )
        let persistenceStartedAt = ContinuousClock.now
        let persistenceState = ScreenshotCaptureMetrics.signposter.beginInterval("Persist")
        do {
            try await ScreenshotContentProvider.shared.persistCapture(record, dbQueue: request.dbQueue)
        } catch {
            ScreenshotCaptureMetrics.signposter.endInterval("Persist", persistenceState)
            ScreenshotCaptureMetrics.recordSlowStage(.persistence, startedAt: persistenceStartedAt)
            guard !Task.isCancelled,
                  lifecycle.accepts(generation: generation) else { return .discarded }
            await request.onFailure(error)
            return .failed
        }
        ScreenshotCaptureMetrics.signposter.endInterval("Persist", persistenceState)
        ScreenshotCaptureMetrics.recordSlowStage(.persistence, startedAt: persistenceStartedAt)

        // The record is durable from here, so later cancellation still reports it as saved.
        guard !Task.isCancelled,
              lifecycle.accepts(generation: generation) else { return .saved }
        await request.onPersisted(record)
        return .saved
    }

    private func finishSave(
        outcome: AutomaticScreenshotCaptureOutcome,
        generation: UInt64
    ) {
        pendingSaveCount -= 1
        // A save is discarded only after its generation ended.
        guard lifecycle.accepts(generation: generation) else { return }
        if outcome == .failed {
            // The references already moved past this frame, so capture the screen again after the backoff.
            settleTracker.forgetReferences()
            lastSavedCropFingerprint = nil
            delayAfterFailure(generation: generation)
        }
        // A capture held back by the pending-save limit may have no frame or timer left to observe it.
        if let attempt = lifecycle.activeAttempt {
            evaluateCapture(attempt: attempt)
        }
    }

    private func delayAfterFailure(generation: UInt64) {
        guard lifecycle.accepts(generation: generation),
              let request = desiredRequest else { return }
        let now = ContinuousClock.now
        failedCaptureRetryNotBefore = now + .seconds(request.intervalSeconds)
        if let attempt = lifecycle.activeAttempt {
            scheduleSettleCheck(after: now, attempt: attempt)
        }
    }

    private func processingScopeMatches(_ request: AutomaticScreenshotCaptureRequest) -> Bool {
        guard let desiredRequest else { return false }
        return desiredRequest.detectsChangesInSharedContentOnly == request.detectsChangesInSharedContentOnly
            && desiredRequest.cropsToSharedContent == request.cropsToSharedContent
    }
}

extension AutomaticScreenshotCaptureService {
    private static func normalized(_ request: AutomaticScreenshotCaptureRequest) -> AutomaticScreenshotCaptureRequest {
        var request = request
        request.intervalSeconds = max(1, request.intervalSeconds)
        if !request.changeThresholdRatio.isFinite {
            request.changeThresholdRatio = 0.05
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
            mimeType: mimeType,
            contentHash: ScreenshotRemoteReference.digest(encodedData),
            contentLength: encodedData.count
        )
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

    /// Change detection needs only a thumbnail; saved images come from `captureScreenshot(filter:)`.
    private static func detectionStreamConfiguration(filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        // Match the source aspect ratio; ScreenCaptureKit letterboxes rather than stretches.
        let size = filter.contentRect.size
        let scale = 320 / max(size.width, size.height, 1)
        configuration.width = max(1, Int((size.width * scale).rounded()))
        configuration.height = max(1, Int((size.height * scale).rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 4)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return configuration
    }

    /// Captures at the content's current native pixel size, which follows window resizes.
    private static func captureScreenshot(filter: SCContentFilter) async throws -> CGImage {
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        // The imported async overload returns Void, so bridge the completion handler directly.
        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureScreenshot(
                contentFilter: filter,
                configuration: configuration
            ) { output, error in
                if let image = output?.sdrImage {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? ScreenshotError.sourceUnavailable)
                }
            }
        }
    }
}

private struct AutomaticScreenshotFrameQueue: Sendable {
    let sampleHandlerQueue = DispatchQueue(
        label: "com.dahlia.automatic-screenshot",
        qos: .utility
    )

    func drain() async {
        await withCheckedContinuation { continuation in
            sampleHandlerQueue.async {
                continuation.resume()
            }
        }
    }
}

/// ScreenCaptureKit invokes this adapter only on its serial frame queue.
private final class AutomaticScreenshotStreamAdapter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias StopHandler = @Sendable (AutomaticScreenshotCaptureAttempt, Error) -> Void

    private let attempt: AutomaticScreenshotCaptureAttempt
    private let frameMailbox: AutomaticScreenshotFrameMailbox
    private let onStopped: StopHandler
    private let isAcceptingFrames = OSAllocatedUnfairLock(initialState: true)

    init(
        attempt: AutomaticScreenshotCaptureAttempt,
        frameMailbox: AutomaticScreenshotFrameMailbox,
        onStopped: @escaping StopHandler
    ) {
        self.attempt = attempt
        self.frameMailbox = frameMailbox
        self.onStopped = onStopped
    }

    func deactivate() {
        let shouldFinish = isAcceptingFrames.withLock { isAccepting in
            defer { isAccepting = false }
            return isAccepting
        }
        if shouldFinish {
            frameMailbox.finish()
        }
    }

    func stream(
        _: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              isAcceptingFrames.withLock({ $0 }),
              Self.isCompleteFrame(sampleBuffer) else { return }
        let copyState = ScreenshotCaptureMetrics.signposter.beginInterval("Copy frame")
        let frame = Self.copyFrame(sampleBuffer)
        ScreenshotCaptureMetrics.signposter.endInterval("Copy frame", copyState)
        guard let frame else { return }
        frameMailbox.yield(frame)
    }

    func stream(_: SCStream, didStopWithError error: Error) {
        deactivate()
        onStopped(attempt, error)
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let statusRawValue = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRawValue) else { return false }
        return status == .complete
    }

    private static func copyFrame(_ sampleBuffer: CMSampleBuffer) -> CopiedScreenshotFrame? {
        guard let pixelBuffer = sampleBuffer.imageBuffer,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        return CopiedScreenshotFrame(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: height,
            bytesPerRow: bytesPerRow,
            pixels: Data(bytes: baseAddress, count: bytesPerRow * height)
        )
    }
}
