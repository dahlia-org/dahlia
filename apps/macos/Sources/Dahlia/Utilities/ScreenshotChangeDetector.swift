import CoreGraphics
import Foundation

struct ScreenshotFingerprint: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

enum ScreenshotChangeDetector {
    private static let fingerprintWidth = 64
    private static let fingerprintHeight = 36
    private static let defaultChangedPixelRatioThreshold = 0.20
    private static let minimumChangedPixelDifference = 8

    static func fingerprint(for image: CGImage) -> ScreenshotFingerprint? {
        let width = fingerprintWidth
        let height = fingerprintHeight
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        let didRender = pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else {
                return false
            }

            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard didRender else { return nil }
        return ScreenshotFingerprint(width: width, height: height, pixels: pixels)
    }

    static func isSignificantlyDifferent(
        _ lhs: ScreenshotFingerprint,
        _ rhs: ScreenshotFingerprint,
        changedPixelRatioThreshold: Double = defaultChangedPixelRatioThreshold
    ) -> Bool {
        guard lhs.width == rhs.width,
              lhs.height == rhs.height,
              lhs.pixels.count == rhs.pixels.count,
              !lhs.pixels.isEmpty
        else {
            return true
        }

        var changedPixelCount = 0

        for index in lhs.pixels.indices where isChanged(lhs.pixels[index], rhs.pixels[index]) {
            changedPixelCount += 1
        }

        let pixelCount = lhs.pixels.count
        let changedPixelRatio = Double(changedPixelCount) / Double(pixelCount)
        let requiredChangedPixelRatio = normalizedChangedPixelRatioThreshold(changedPixelRatioThreshold)

        return changedPixelRatio >= requiredChangedPixelRatio
    }

    static func isChanged(_ lhs: UInt8, _ rhs: UInt8) -> Bool {
        abs(Int(lhs) - Int(rhs)) >= minimumChangedPixelDifference
    }

    private static func normalizedChangedPixelRatioThreshold(_ threshold: Double) -> Double {
        guard threshold.isFinite else { return defaultChangedPixelRatioThreshold }
        return min(max(threshold, 0.01), 1.0)
    }
}

/// Tracks when each fingerprint pixel last moved so that captures compare only the still part of the screen.
/// Continuously moving areas such as camera video never settle, so they neither trigger nor dilute a capture.
struct ScreenshotSettleTracker {
    static let settleDuration: Duration = .seconds(1)

    private var anchors: [UInt8] = []
    private var changedAt: [ContinuousClock.Instant] = []
    private var latestPixels: [UInt8] = []
    private var savedPixels: [UInt8]?
    private var attemptedPixels: [UInt8]?
    private var lastCaptureAt: ContinuousClock.Instant?
    private var lastMostlySettledAt: ContinuousClock.Instant?

    /// The reference a capture decision compares against.
    enum Baseline {
        /// The last saved frame, so small changes keep adding up until they reach the threshold.
        case lastSaved
        /// The last capture attempt, so the shared-content gate does not re-trigger on a change it already checked.
        case lastAttempt
    }

    /// The references a capture leaves behind. Commit them only once the frame is saved or intentionally skipped,
    /// so a failed or discarded capture keeps its change pending.
    struct CaptureReference: Sendable {
        fileprivate let savedPixels: [UInt8]
        fileprivate let attemptedPixels: [UInt8]
        fileprivate let capturedAt: ContinuousClock.Instant
    }

    mutating func ingest(_ fingerprint: ScreenshotFingerprint, at now: ContinuousClock.Instant) {
        let pixels = fingerprint.pixels
        if anchors.count != pixels.count {
            anchors = pixels
            changedAt = Array(repeating: now, count: pixels.count)
            savedPixels = nil
            attemptedPixels = nil
            lastMostlySettledAt = now
        }
        // Sample before applying this frame: frames stop while the display is idle, so a gap means it was still.
        if !isMostlyMoving(at: now) {
            lastMostlySettledAt = now
        }
        // Comparing with the anchor instead of the previous frame keeps slow fades from looking settled.
        for index in pixels.indices where ScreenshotChangeDetector.isChanged(anchors[index], pixels[index]) {
            anchors[index] = pixels[index]
            changedAt[index] = now
        }
        latestPixels = pixels
    }

    /// When the most recent movement settles, or nil when it has already settled by `now`.
    func settleDeadline(after now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard let lastChange = changedAt.max() else { return nil }
        let deadline = lastChange + Self.settleDuration
        return deadline > now ? deadline : nil
    }

    func shouldCapture(
        at now: ContinuousClock.Instant,
        maximumInterval: Duration,
        changeThresholdRatio: Double,
        comparedWith baseline: Baseline
    ) -> Bool {
        guard !latestPixels.isEmpty else { return false }
        guard let reference = baseline == .lastSaved ? savedPixels : attemptedPixels,
              let lastCaptureAt else { return true }
        var settledCount = 0
        var settledChangeCount = 0
        var changeCount = 0
        for index in latestPixels.indices {
            let isChanged = ScreenshotChangeDetector.isChanged(reference[index], latestPixels[index])
            if isChanged {
                changeCount += 1
            }
            if isSettled(index, at: now) {
                settledCount += 1
                if isChanged {
                    settledChangeCount += 1
                }
            }
        }
        // The half-screen floor keeps small still areas, such as subtitles over video, from looking like a full change.
        let settledArea = max(settledCount, latestPixels.count / 2)
        if Double(settledChangeCount) / Double(settledArea) >= changeThresholdRatio {
            return true
        }
        // ponytail: a fixed half-screen cutoff separates full-screen video from camera tiles; tune with real meetings.
        guard settledCount * 2 < latestPixels.count,
              let lastMostlySettledAt,
              now - lastMostlySettledAt >= maximumInterval,
              now - lastCaptureAt >= maximumInterval else { return false }
        return Double(changeCount) / Double(latestPixels.count) >= changeThresholdRatio
    }

    func captureReference(at now: ContinuousClock.Instant) -> CaptureReference {
        CaptureReference(
            savedPixels: updated(savedPixels, at: now),
            attemptedPixels: updated(attemptedPixels, at: now),
            capturedAt: now
        )
    }

    /// Saved frames replace both baselines. Intentionally skipped frames replace only the last attempt,
    /// so smaller changes keep adding up against the last saved frame.
    mutating func commit(_ reference: CaptureReference, isSaved: Bool) {
        attemptedPixels = reference.attemptedPixels
        lastCaptureAt = reference.capturedAt
        if isSaved {
            savedPixels = reference.savedPixels
        }
    }

    /// Makes the next check capture unconditionally, as for the first frame. A save that fails after its
    /// reference was committed cannot be uncommitted precisely, so the current screen is captured again instead.
    mutating func forgetReferences() {
        savedPixels = nil
        attemptedPixels = nil
    }

    private func updated(_ reference: [UInt8]?, at now: ContinuousClock.Instant) -> [UInt8] {
        guard var reference else { return latestPixels }
        // Pixels still moving keep their old reference so their final state is evaluated once they settle.
        // A mostly moving screen is compared as a whole, so the whole frame becomes the reference.
        let updatesAllPixels = isMostlyMoving(at: now)
        for index in latestPixels.indices where updatesAllPixels || isSettled(index, at: now) {
            reference[index] = latestPixels[index]
        }
        return reference
    }

    private func isSettled(_ index: Int, at now: ContinuousClock.Instant) -> Bool {
        now - changedAt[index] >= Self.settleDuration
    }

    private func isMostlyMoving(at now: ContinuousClock.Instant) -> Bool {
        changedAt.count(where: { now - $0 < Self.settleDuration }) * 2 > changedAt.count
    }
}
