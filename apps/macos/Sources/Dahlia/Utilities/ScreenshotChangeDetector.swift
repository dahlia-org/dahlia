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

/// Tracks how each fingerprint pixel moves so that adaptive captures wait until the screen stops changing.
/// Areas that keep changing, such as camera video, a moving cursor, or an animation, are live: they neither trigger,
/// delay, nor add up to a capture.
struct ScreenshotSettleTracker {
    static let settleDuration: Duration = .seconds(1)
    /// A change that settled within this window counts as one change at once, such as a slide transition or a scroll,
    /// and is saved right away instead of waiting for the interval.
    private static let changeWindow: Duration = .seconds(3)
    // ponytail: tuned on synthetic meetings with camera tiles, scrolling, and slides; retune with recorded fingerprints.
    /// Small changes count toward making the pixels around them live, and the count fades over this time.
    private static let liveMemory: Duration = .seconds(20)
    private static let liveChangeCount = 3.0
    /// A small change also counts for neighbors this close, so a camera tile is live even where each pixel rarely moves.
    private static let liveRadius = 2
    /// Motion without a settled moment for this long is live, like video, even when it changes much of the screen.
    private static let continuousMotionLimit: Duration = .seconds(20)

    private var width = 0
    private var anchors: [UInt8] = []
    private var changedAt: [ContinuousClock.Instant] = []
    private var movingSince: [ContinuousClock.Instant] = []
    private var smallChangeCounts: [Double] = []
    private var ingestedAt: ContinuousClock.Instant?
    private var latestPixels: [UInt8] = []
    private var savedPixels: [UInt8]?
    private var lastCaptureAt: ContinuousClock.Instant?
    private var lastMostlySettledAt: ContinuousClock.Instant?

    /// The reference a capture leaves behind. Commit it only once the frame is saved or intentionally skipped,
    /// so a failed or discarded capture keeps its change pending.
    struct CaptureReference: Sendable {
        fileprivate let savedPixels: [UInt8]
        fileprivate let capturedAt: ContinuousClock.Instant
    }

    mutating func ingest(
        _ fingerprint: ScreenshotFingerprint,
        at now: ContinuousClock.Instant,
        changeThresholdRatio: Double
    ) {
        let pixels = fingerprint.pixels
        if anchors.count != pixels.count {
            width = fingerprint.width
            anchors = pixels
            changedAt = Array(repeating: now, count: pixels.count)
            movingSince = changedAt
            smallChangeCounts = Array(repeating: 0, count: pixels.count)
            savedPixels = nil
            lastMostlySettledAt = now
        }
        // Sample before applying this frame: frames stop while the display is idle, so a gap means it was still.
        if !isMostlyMoving(at: now) {
            lastMostlySettledAt = now
        }
        // Comparing with the anchor instead of the previous frame keeps slow fades from looking settled.
        let changedIndices = pixels.indices.filter { ScreenshotChangeDetector.isChanged(anchors[$0], pixels[$0]) }
        let decay = liveDecay(at: now)
        for index in smallChangeCounts.indices {
            smallChangeCounts[index] *= decay
        }
        // A change large enough to be saved by itself, such as a slide or a scroll step, is content. Only smaller
        // changes repeating in one place, such as people moving in camera tiles, make that place live.
        if Double(changedIndices.count) < changeThresholdRatio * Double(pixels.count) {
            for index in neighborhood(of: changedIndices) {
                smallChangeCounts[index] += 1
            }
        }
        for index in changedIndices {
            if isSettled(index, at: now) {
                movingSince[index] = now
            }
            anchors[index] = pixels[index]
            changedAt[index] = now
        }
        ingestedAt = now
        latestPixels = pixels
    }

    /// When the next check falls due without a new frame: once the latest movement settles with an adaptive interval,
    /// or once `interval` has passed since the last capture. Nil when nothing falls due after `now`.
    func checkDeadline(
        after now: ContinuousClock.Instant,
        interval: Duration,
        isAdaptive: Bool
    ) -> ContinuousClock.Instant? {
        let settleDeadline = isAdaptive ? changedAt.max().map { $0 + Self.settleDuration } : nil
        return [settleDeadline, lastCaptureAt.map { $0 + interval }]
            .compactMap(\.self)
            .filter { $0 > now }
            .min()
    }

    /// An adaptive interval waits until everything except live areas stops moving, then captures a change that settled
    /// at once. Changes that added up gradually, or that never stop moving, are checked once `interval` has passed.
    /// A fixed interval compares the whole screen once `interval` has passed since the last capture.
    func shouldCapture(
        at now: ContinuousClock.Instant,
        interval: Duration,
        isAdaptive: Bool,
        changeThresholdRatio: Double
    ) -> Bool {
        guard !latestPixels.isEmpty else { return false }
        guard let savedPixels, let lastCaptureAt else { return true }
        let decay = liveDecay(at: now)
        var movingCount = 0
        var settledCount = 0
        var settledChangeCount = 0
        var recentChangeCount = 0
        var changeCount = 0
        for index in latestPixels.indices {
            let isChanged = ScreenshotChangeDetector.isChanged(savedPixels[index], latestPixels[index])
            if isChanged {
                changeCount += 1
            }
            guard isAdaptive, !isLive(index, at: now, decay: decay) else { continue }
            guard isSettled(index, at: now) else {
                movingCount += 1
                continue
            }
            settledCount += 1
            if isChanged {
                settledChangeCount += 1
                if now - changedAt[index] < Self.changeWindow {
                    recentChangeCount += 1
                }
            }
        }
        let pixelCount = Double(latestPixels.count)
        let wholeScreenChanged = Double(changeCount) / pixelCount >= changeThresholdRatio
        let isIntervalDue = now - lastCaptureAt >= interval
        guard isAdaptive else {
            return isIntervalDue && wholeScreenChanged
        }
        // The half-screen floor keeps small still areas, such as subtitles over video, from looking like a full change.
        let settledArea = Double(max(settledCount, latestPixels.count / 2))
        if Double(settledChangeCount) / settledArea >= changeThresholdRatio {
            // Motion below the threshold, such as a cursor, cannot be a threshold-sized change by itself.
            let isQuiet = Double(movingCount) < changeThresholdRatio * pixelCount
            if isIntervalDue || (isQuiet && Double(recentChangeCount) / settledArea >= changeThresholdRatio) {
                return true
            }
        }
        guard settledCount * 2 < latestPixels.count,
              let lastMostlySettledAt,
              now - lastMostlySettledAt >= interval,
              isIntervalDue else { return false }
        return wholeScreenChanged
    }

    func captureReference(at now: ContinuousClock.Instant, isAdaptive: Bool) -> CaptureReference {
        CaptureReference(savedPixels: updatedReference(at: now, isAdaptive: isAdaptive), capturedAt: now)
    }

    mutating func commit(_ reference: CaptureReference) {
        savedPixels = reference.savedPixels
        lastCaptureAt = reference.capturedAt
    }

    /// Makes the next check capture unconditionally, as for the first frame. A save that fails after its
    /// reference was committed cannot be uncommitted precisely, so the current screen is captured again instead.
    mutating func forgetReferences() {
        savedPixels = nil
    }

    private func updatedReference(at now: ContinuousClock.Instant, isAdaptive: Bool) -> [UInt8] {
        // A fixed interval or a mostly moving screen is compared as a whole, so the whole frame becomes the reference.
        guard var reference = savedPixels, isAdaptive, !isMostlyMoving(at: now) else { return latestPixels }
        // Pixels still moving keep their old reference so their final state is evaluated once they settle.
        // Live pixels follow the screen so that their changes never add up.
        let decay = liveDecay(at: now)
        for index in latestPixels.indices where isLive(index, at: now, decay: decay) || isSettled(index, at: now) {
            reference[index] = latestPixels[index]
        }
        return reference
    }

    private func isSettled(_ index: Int, at now: ContinuousClock.Instant) -> Bool {
        now - changedAt[index] >= Self.settleDuration
    }

    /// Whether live or moving pixels cover most of the screen, as during full-screen video or a camera gallery.
    private func isMostlyMoving(at now: ContinuousClock.Instant) -> Bool {
        let decay = liveDecay(at: now)
        return changedAt.indices.count(where: { isLive($0, at: now, decay: decay) || !isSettled($0, at: now) }) * 2
            > changedAt.count
    }

    private func isLive(_ index: Int, at now: ContinuousClock.Instant, decay: Double) -> Bool {
        smallChangeCounts[index] * decay >= Self.liveChangeCount
            || (!isSettled(index, at: now) && now - movingSince[index] >= Self.continuousMotionLimit)
    }

    /// The given pixels and those within `liveRadius` of them, each once.
    private func neighborhood(of indices: [Int]) -> [Int] {
        let height = changedAt.count / width
        var isIncluded = [Bool](repeating: false, count: changedAt.count)
        for index in indices {
            let x = index % width
            let y = index / width
            for row in max(0, y - Self.liveRadius) ... min(height - 1, y + Self.liveRadius) {
                for column in max(0, x - Self.liveRadius) ... min(width - 1, x + Self.liveRadius) {
                    isIncluded[row * width + column] = true
                }
            }
        }
        return isIncluded.indices.filter { isIncluded[$0] }
    }

    private func liveDecay(at now: ContinuousClock.Instant) -> Double {
        guard let ingestedAt else { return 1 }
        return exp(-((now - ingestedAt) / Self.liveMemory))
    }
}
