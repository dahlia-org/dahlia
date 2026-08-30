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

struct AutomaticScreenshotPixelDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
}

enum AutomaticScreenshotFrameResolutionAction: Equatable, Sendable {
    case process
    case discard
    case updateConfiguration(AutomaticScreenshotPixelDimensions)
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
    let capturedAt: Date
    var sourcePixelDimensions: AutomaticScreenshotPixelDimensions?

    var pixelDimensions: AutomaticScreenshotPixelDimensions {
        AutomaticScreenshotPixelDimensions(width: width, height: height)
    }

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

    struct PendingFrame {
        let attempt: AutomaticScreenshotCaptureAttempt
        let frame: CopiedScreenshotFrame
    }

    private(set) var operation: Operation?
    private(set) var pendingFrame: PendingFrame?
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

    mutating func queueLatest(
        _ frame: CopiedScreenshotFrame,
        attempt: AutomaticScreenshotCaptureAttempt
    ) -> Bool {
        guard operation?.attempt == attempt else { return false }
        pendingFrame = PendingFrame(attempt: attempt, frame: frame)
        return true
    }

    mutating func discardPendingFrame(matching attempt: AutomaticScreenshotCaptureAttempt) {
        guard pendingFrame?.attempt == attempt else { return }
        pendingFrame = nil
    }

    mutating func complete(
        operationID: UInt64,
        attempt: AutomaticScreenshotCaptureAttempt
    ) -> PendingFrame? {
        guard let operation,
              operation.id == operationID,
              operation.attempt == attempt else { return nil }
        self.operation = nil
        defer { pendingFrame = nil }
        guard pendingFrame?.attempt == attempt else { return nil }
        return pendingFrame
    }

    mutating func take(
        matching attempt: AutomaticScreenshotCaptureAttempt? = nil
    ) -> Operation? {
        if attempt == nil || pendingFrame?.attempt == attempt {
            pendingFrame = nil
        }
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
}

struct AutomaticScreenshotFingerprintBaseline {
    private(set) var value: ScreenshotFingerprint?

    mutating func reset() {
        value = nil
    }

    mutating func record(
        _ fingerprint: ScreenshotFingerprint,
        detectionScopeMatches: Bool
    ) {
        guard detectionScopeMatches else { return }
        value = fingerprint
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
        _ frame: CopiedScreenshotFrame,
        detectsChangesInSharedContentOnly: Bool,
        cropsToSharedContent: Bool
    ) async -> PreparedScreenshotFrame? {
        guard !Task.isCancelled, let image = frame.makeImage() else { return nil }
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
        let startedAt = ContinuousClock.now
        let state = ScreenshotCaptureMetrics.signposter.beginInterval("Fingerprint")
        let fingerprint = ScreenshotChangeDetector.fingerprint(for: selectedImages.fingerprint)
        ScreenshotCaptureMetrics.signposter.endInterval("Fingerprint", state)
        ScreenshotCaptureMetrics.recordSlowStage(.fingerprint, startedAt: startedAt)
        guard !Task.isCancelled, let fingerprint else { return nil }
        return PreparedScreenshotFrame(
            imageToEncode: selectedImages.encoding,
            fingerprint: fingerprint
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

    fileprivate func encode(_ image: CGImage) -> EncodedScreenshotFrame? {
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

/// Owns the periodic ScreenCaptureKit stream and keeps image-sized work off MainActor.
actor AutomaticScreenshotCaptureService: AutomaticScreenshotCapturing {
    private struct ActiveCapture {
        let attempt: AutomaticScreenshotCaptureAttempt
        let stream: SCStream
        let adapter: AutomaticScreenshotStreamAdapter
        let configuration: SCStreamConfiguration
        let frameConsumerTask: Task<Void, Never>
    }

    private var lifecycle = AutomaticScreenshotCaptureLifecycle()
    private let frameProcessor = AutomaticScreenshotFrameProcessor()
    private let frameQueue = AutomaticScreenshotFrameQueue()
    private var desiredRequest: AutomaticScreenshotCaptureRequest?
    private var activeCapture: ActiveCapture?
    private var processingState = AutomaticScreenshotProcessingState()
    private var fingerprintBaseline = AutomaticScreenshotFingerprintBaseline()
    private var retryTask: Task<Void, Never>?

    func start(_ request: AutomaticScreenshotCaptureRequest) async {
        desiredRequest = Self.normalized(request)
        retryTask?.cancel()
        retryTask = nil
        let generation = lifecycle.beginReplacement()
        await stopCaptureAndProcessing()
        guard lifecycle.accepts(generation: generation) else { return }
        fingerprintBaseline.reset()
        await startStream(generation: generation)
    }

    func updateSettings(
        intervalSeconds: Int,
        changeThresholdRatio: Double,
        detectsChangesInSharedContentOnly: Bool,
        cropsToSharedContent: Bool
    ) async {
        guard var request = desiredRequest else { return }
        let detectionScopeChanged = request.detectsChangesInSharedContentOnly != detectsChangesInSharedContentOnly
        let sharedContentSettingsChanged = detectionScopeChanged || request.cropsToSharedContent != cropsToSharedContent
        request.intervalSeconds = intervalSeconds
        request.changeThresholdRatio = changeThresholdRatio
        request.detectsChangesInSharedContentOnly = detectsChangesInSharedContentOnly
        request.cropsToSharedContent = cropsToSharedContent
        request = Self.normalized(request)
        desiredRequest = request
        if detectionScopeChanged {
            fingerprintBaseline.reset()
        }
        if sharedContentSettingsChanged {
            await frameProcessor.resetSharedContentRegion()
        }

        guard let activeCapture,
              lifecycle.accepts(attempt: activeCapture.attempt) else { return }
        activeCapture.configuration.minimumFrameInterval = Self.frameInterval(
            seconds: request.intervalSeconds
        )
        do {
            try await activeCapture.stream.updateConfiguration(activeCapture.configuration)
        } catch {
            await handleRuntimeFailure(error, attempt: activeCapture.attempt)
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
        let processingOperation = processingState.take()
        processingOperation?.task.cancel()
        await stopActiveCapture()
        await processingOperation?.task.value
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
            let configuration = Self.streamConfiguration(
                filter: filter,
                intervalSeconds: request.intervalSeconds
            )
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
            let stream = SCStream(filter: filter, configuration: configuration, delegate: adapter)
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
                adapter: adapter,
                configuration: configuration,
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
    ) async {
        guard lifecycle.accepts(attempt: attempt) else { return }
        if await shouldDiscardFrameForResolution(for: frame, attempt: attempt) {
            return
        }
        if processingState.isProcessing {
            _ = processingState.queueLatest(frame, attempt: attempt)
            return
        }
        startProcessing(frame, attempt: attempt)
    }

    private func startProcessing(
        _ frame: CopiedScreenshotFrame,
        attempt: AutomaticScreenshotCaptureAttempt
    ) {
        processingState.begin(attempt: attempt) { [weak self] operationID in
            Task(priority: .utility) {
                await self?.process(frame, attempt: attempt)
                await self?.finishProcessing(operationID: operationID, attempt: attempt)
            }
        }
    }

    private func process(
        _ frame: CopiedScreenshotFrame,
        attempt: AutomaticScreenshotCaptureAttempt
    ) async {
        guard lifecycle.accepts(attempt: attempt),
              let request = desiredRequest else { return }
        let preparedFrame = await frameProcessor.prepare(
            frame,
            detectsChangesInSharedContentOnly: request.detectsChangesInSharedContentOnly,
            cropsToSharedContent: request.cropsToSharedContent
        )
        guard let preparedFrame,
              !Task.isCancelled,
              lifecycle.accepts(attempt: attempt),
              processingScopeMatches(request) else { return }

        guard shouldSave(
            preparedFrame.fingerprint,
            changeThresholdRatio: request.changeThresholdRatio
        ) else { return }

        guard let encoded = await frameProcessor.encode(preparedFrame.imageToEncode) else {
            guard !Task.isCancelled,
                  lifecycle.accepts(attempt: attempt),
                  processingScopeMatches(request) else { return }
            await request.onFailure(ScreenshotError.encodingFailed)
            return
        }
        guard !Task.isCancelled,
              lifecycle.accepts(attempt: attempt),
              processingScopeMatches(request) else { return }
        guard shouldSave(
            preparedFrame.fingerprint,
            changeThresholdRatio: request.changeThresholdRatio
        ) else { return }

        let record = Self.makeRecord(
            frame: frame,
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
                  lifecycle.accepts(attempt: attempt) else { return }
            await request.onFailure(error)
            return
        }
        ScreenshotCaptureMetrics.signposter.endInterval("Persist", persistenceState)
        ScreenshotCaptureMetrics.recordSlowStage(.persistence, startedAt: persistenceStartedAt)

        guard !Task.isCancelled,
              lifecycle.accepts(attempt: attempt) else { return }
        fingerprintBaseline.record(
            preparedFrame.fingerprint,
            detectionScopeMatches: detectionScopeMatches(request)
        )
        await request.onPersisted(record)
    }

    private func finishProcessing(
        operationID: UInt64,
        attempt: AutomaticScreenshotCaptureAttempt
    ) {
        guard let pendingFrame = processingState.complete(
            operationID: operationID,
            attempt: attempt
        ) else { return }
        guard lifecycle.accepts(attempt: attempt) else { return }
        startProcessing(pendingFrame.frame, attempt: attempt)
    }

    private func shouldSave(
        _ fingerprint: ScreenshotFingerprint,
        changeThresholdRatio: Double
    ) -> Bool {
        guard let lastSavedFingerprint = fingerprintBaseline.value else { return true }
        return ScreenshotChangeDetector.isSignificantlyDifferent(
            lastSavedFingerprint,
            fingerprint,
            changedPixelRatioThreshold: changeThresholdRatio
        )
    }

    private func processingScopeMatches(_ request: AutomaticScreenshotCaptureRequest) -> Bool {
        guard let desiredRequest else { return false }
        return desiredRequest.detectsChangesInSharedContentOnly == request.detectsChangesInSharedContentOnly
            && desiredRequest.cropsToSharedContent == request.cropsToSharedContent
    }

    private func detectionScopeMatches(_ request: AutomaticScreenshotCaptureRequest) -> Bool {
        desiredRequest?.detectsChangesInSharedContentOnly == request.detectsChangesInSharedContentOnly
    }
}

extension AutomaticScreenshotCaptureService {
    private func shouldDiscardFrameForResolution(
        for frame: CopiedScreenshotFrame,
        attempt: AutomaticScreenshotCaptureAttempt
    ) async -> Bool {
        guard let activeCapture, activeCapture.attempt == attempt else { return false }
        let configuredDimensions = AutomaticScreenshotPixelDimensions(
            width: activeCapture.configuration.width,
            height: activeCapture.configuration.height
        )
        switch Self.frameResolutionAction(
            frameDimensions: frame.pixelDimensions,
            sourcePixelDimensions: frame.sourcePixelDimensions,
            configuredDimensions: configuredDimensions
        ) {
        case .process:
            return false
        case .discard:
            return true
        case let .updateConfiguration(dimensions):
            processingState.discardPendingFrame(matching: attempt)
            activeCapture.configuration.width = dimensions.width
            activeCapture.configuration.height = dimensions.height
            do {
                try await activeCapture.stream.updateConfiguration(activeCapture.configuration)
            } catch {
                // Failure cleanup joins the frame consumer, so it must run from another task.
                Task { [weak self] in
                    await self?.handleRuntimeFailure(error, attempt: attempt)
                }
            }
            return true
        }
    }

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
        frame: CopiedScreenshotFrame,
        meetingID: UUID,
        sessionID: UUID?,
        encodedData: Data,
        mimeType: String
    ) -> MeetingScreenshotRecord {
        MeetingScreenshotRecord(
            id: UUID.v7(),
            meetingId: meetingID,
            sessionId: sessionID,
            capturedAt: frame.capturedAt,
            imageData: encodedData,
            mimeType: mimeType
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

    private static func streamConfiguration(
        filter: SCContentFilter,
        intervalSeconds: Int
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((filter.contentRect.width * Double(filter.pointPixelScale)).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * Double(filter.pointPixelScale)).rounded()))
        configuration.minimumFrameInterval = frameInterval(seconds: intervalSeconds)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureResolution = .best
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return configuration
    }

    private static func frameInterval(seconds: Int) -> CMTime {
        CMTime(seconds: Double(max(1, seconds)), preferredTimescale: 600)
    }

    static func sourcePixelDimensions(
        contentRect: CGRect,
        contentScale: CGFloat,
        scaleFactor: CGFloat
    ) -> AutomaticScreenshotPixelDimensions? {
        guard contentRect.width > 0,
              contentRect.height > 0,
              contentScale > 0,
              scaleFactor > 0,
              contentRect.width.isFinite,
              contentRect.height.isFinite,
              contentScale.isFinite,
              scaleFactor.isFinite else { return nil }
        return AutomaticScreenshotPixelDimensions(
            width: max(1, Int((contentRect.width / contentScale * scaleFactor).rounded())),
            height: max(1, Int((contentRect.height / contentScale * scaleFactor).rounded()))
        )
    }

    static func sourcePixelDimensions(
        from attachments: [SCStreamFrameInfo: Any]
    ) -> AutomaticScreenshotPixelDimensions? {
        guard let contentRect = contentRect(from: attachments[.contentRect]),
              let contentScale = attachments[.contentScale] as? CGFloat,
              let scaleFactor = attachments[.scaleFactor] as? CGFloat else { return nil }
        return sourcePixelDimensions(
            contentRect: contentRect,
            contentScale: contentScale,
            scaleFactor: scaleFactor
        )
    }

    static func contentRect(from value: Any?) -> CGRect? {
        guard let value else { return nil }
        if let contentRect = value as? CGRect {
            return contentRect
        }
        guard let dictionary = value as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary)
    }

    static func frameResolutionAction(
        frameDimensions: AutomaticScreenshotPixelDimensions,
        sourcePixelDimensions: AutomaticScreenshotPixelDimensions?,
        configuredDimensions: AutomaticScreenshotPixelDimensions
    ) -> AutomaticScreenshotFrameResolutionAction {
        guard frameDimensions == configuredDimensions else {
            return .discard
        }
        if let sourcePixelDimensions, sourcePixelDimensions != configuredDimensions {
            return .updateConfiguration(sourcePixelDimensions)
        }
        return .process
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
        let capturedAt = Date.now
        let copyState = ScreenshotCaptureMetrics.signposter.beginInterval("Copy frame")
        let frame = Self.copyFrame(sampleBuffer, capturedAt: capturedAt)
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

    private static func copyFrame(
        _ sampleBuffer: CMSampleBuffer,
        capturedAt: Date
    ) -> CopiedScreenshotFrame? {
        guard let pixelBuffer = sampleBuffer.imageBuffer,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let sourcePixelDimensions = frameAttachments(sampleBuffer).flatMap {
            AutomaticScreenshotCaptureService.sourcePixelDimensions(from: $0)
        }
        return CopiedScreenshotFrame(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixels: Data(bytes: baseAddress, count: bytesPerRow * height),
            capturedAt: capturedAt,
            sourcePixelDimensions: sourcePixelDimensions
        )
    }

    private static func frameAttachments(
        _ sampleBuffer: CMSampleBuffer
    ) -> [SCStreamFrameInfo: Any]? {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]]
        return attachments?.first
    }
}
