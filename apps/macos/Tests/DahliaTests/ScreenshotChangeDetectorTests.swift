import CoreGraphics
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct ScreenshotChangeDetectorTests {
        @Test
        func identicalImagesAreNotDifferent() throws {
            let image = try makeImage(width: 640, height: 360, background: .black)

            let first = try #require(ScreenshotChangeDetector.fingerprint(for: image))
            let second = try #require(ScreenshotChangeDetector.fingerprint(for: image))

            #expect(!ScreenshotChangeDetector.isSignificantlyDifferent(first, second))
        }

        @Test
        func smallLocalChangeIsIgnored() throws {
            let baseline = try makeImage(width: 640, height: 360, background: .black)
            let changed = try makeImage(
                width: 640,
                height: 360,
                background: .black,
                patches: [
                    Patch(rect: CGRect(x: 24, y: 24, width: 8, height: 8), color: .white),
                ]
            )

            let first = try #require(ScreenshotChangeDetector.fingerprint(for: baseline))
            let second = try #require(ScreenshotChangeDetector.fingerprint(for: changed))

            #expect(!ScreenshotChangeDetector.isSignificantlyDifferent(first, second))
        }

        @Test
        func largeChangeIsSignificant() throws {
            let baseline = try makeImage(width: 640, height: 360, background: .black)
            let changed = try makeImage(width: 640, height: 360, background: .white)

            let first = try #require(ScreenshotChangeDetector.fingerprint(for: baseline))
            let second = try #require(ScreenshotChangeDetector.fingerprint(for: changed))

            #expect(ScreenshotChangeDetector.isSignificantlyDifferent(first, second))
        }

        @Test
        func changedPixelRatioThresholdControlsLocalChanges() throws {
            let baseline = try makeImage(width: 640, height: 360, background: .black)
            let changed = try makeImage(
                width: 640,
                height: 360,
                background: .black,
                patches: [
                    Patch(
                        rect: CGRect(x: 0, y: 0, width: 96, height: 360),
                        color: CGColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1)
                    ),
                ]
            )

            let first = try #require(ScreenshotChangeDetector.fingerprint(for: baseline))
            let second = try #require(ScreenshotChangeDetector.fingerprint(for: changed))

            #expect(ScreenshotChangeDetector.isSignificantlyDifferent(first, second, changedPixelRatioThreshold: 0.10))
            #expect(!ScreenshotChangeDetector.isSignificantlyDifferent(first, second, changedPixelRatioThreshold: 0.20))
        }

        @Test
        func highContrastLocalChangeRespectsConfiguredThreshold() throws {
            let baseline = try makeImage(width: 640, height: 360, background: .black)
            let changed = try makeImage(
                width: 640,
                height: 360,
                background: .black,
                patches: [
                    Patch(rect: CGRect(x: 0, y: 0, width: 80, height: 360), color: .white),
                ]
            )

            let first = try #require(ScreenshotChangeDetector.fingerprint(for: baseline))
            let second = try #require(ScreenshotChangeDetector.fingerprint(for: changed))

            #expect(ScreenshotChangeDetector.isSignificantlyDifferent(first, second, changedPixelRatioThreshold: 0.10))
            #expect(!ScreenshotChangeDetector.isSignificantlyDifferent(first, second, changedPixelRatioThreshold: 0.20))
        }

        @Test
        func screenWideLowContrastChangeIsSignificant() throws {
            let baseline = try makeImage(width: 640, height: 360, background: .black)
            let changed = try makeImage(
                width: 640,
                height: 360,
                background: CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
            )

            let first = try #require(ScreenshotChangeDetector.fingerprint(for: baseline))
            let second = try #require(ScreenshotChangeDetector.fingerprint(for: changed))

            #expect(ScreenshotChangeDetector.isSignificantlyDifferent(first, second, changedPixelRatioThreshold: 0.50))
        }

        @Test
        func sameRelativeContentAtDifferentSizesIsStable() throws {
            let firstImage = try makeImage(
                width: 640,
                height: 360,
                background: .black,
                patches: [
                    Patch(rect: CGRect(x: 0, y: 0, width: 320, height: 360), color: .white),
                ]
            )
            let secondImage = try makeImage(
                width: 1280,
                height: 720,
                background: .black,
                patches: [
                    Patch(rect: CGRect(x: 0, y: 0, width: 640, height: 720), color: .white),
                ]
            )

            let first = try #require(ScreenshotChangeDetector.fingerprint(for: firstImage))
            let second = try #require(ScreenshotChangeDetector.fingerprint(for: secondImage))

            #expect(!ScreenshotChangeDetector.isSignificantlyDifferent(first, second))
        }
    }

    private struct Patch {
        let rect: CGRect
        let color: CGColor
    }

    private enum TestImageError: Error {
        case contextUnavailable
        case imageUnavailable
    }

    private func makeImage(
        width: Int,
        height: Int,
        background: CGColor,
        patches: [Patch] = []
    ) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestImageError.contextUnavailable
        }

        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for patch in patches {
            context.setFillColor(patch.color)
            context.fill(patch.rect)
        }

        guard let image = context.makeImage() else {
            throw TestImageError.imageUnavailable
        }
        return image
    }

    struct ScreenshotSettleTrackerTests {
        private let start = ContinuousClock.now
        private let maximumInterval: Duration = .seconds(20)
        private let threshold = 0.20

        @Test
        func firstFrameIsCapturedImmediately() {
            var tracker = ScreenshotSettleTracker()
            ingest(&tracker, fingerprint { _, _ in 0 }, at: start)

            #expect(shouldCapture(tracker, at: start))
        }

        @Test
        func changeIsCapturedOnlyAfterItStopsMoving() throws {
            var tracker = capturedTracker()
            let changedAt = start + .seconds(5)
            ingest(&tracker, fingerprint { x, y in isSlide(x, y) ? 200 : 0 }, at: changedAt)

            #expect(!shouldCapture(tracker, at: changedAt))
            let deadline = try #require(tracker.checkDeadline(after: changedAt, interval: maximumInterval, isAdaptive: true))
            #expect(deadline == changedAt + ScreenshotSettleTracker.settleDuration)
            #expect(shouldCapture(tracker, at: deadline))

            tracker.commit(tracker.captureReference(at: deadline, isAdaptive: true))
            #expect(!shouldCapture(tracker, at: deadline))
        }

        @Test
        func fixedIntervalComparesTheWholeScreenOncePerInterval() throws {
            var tracker = capturedTracker()
            let changedAt = start + maximumInterval - .milliseconds(500)
            ingest(&tracker, fingerprint { _, _ in 200 }, at: changedAt)

            #expect(!shouldCapture(tracker, at: changedAt, isAdaptive: false))
            let deadline = try #require(tracker.checkDeadline(after: changedAt, interval: maximumInterval, isAdaptive: false))
            #expect(deadline == start + maximumInterval)
            // An adaptive interval checks again once the change settles.
            #expect(
                tracker.checkDeadline(after: deadline, interval: maximumInterval, isAdaptive: true)
                    == changedAt + ScreenshotSettleTracker.settleDuration
            )
            // Only an adaptive interval waits for the change to settle.
            #expect(!shouldCapture(tracker, at: deadline))
            #expect(shouldCapture(tracker, at: deadline, isAdaptive: false))

            // The whole frame becomes the reference, including pixels that had not settled.
            tracker.commit(tracker.captureReference(at: deadline, isAdaptive: false))
            #expect(!shouldCapture(tracker, at: deadline + maximumInterval, isAdaptive: false))
        }

        @Test
        func uncommittedCaptureKeepsChangePending() {
            var tracker = capturedTracker()
            let changedAt = start + .seconds(5)
            ingest(&tracker, fingerprint { x, y in isSlide(x, y) ? 200 : 0 }, at: changedAt)
            let settledAt = changedAt + ScreenshotSettleTracker.settleDuration

            // A failed or discarded capture never commits its reference, so the change is retried.
            _ = tracker.captureReference(at: settledAt, isAdaptive: true)
            #expect(shouldCapture(tracker, at: settledAt))

            tracker.commit(tracker.captureReference(at: settledAt, isAdaptive: true))
            #expect(!shouldCapture(tracker, at: settledAt))
        }

        @Test
        func forgottenReferencesCaptureTheUnchangedScreenAgain() {
            var tracker = capturedTracker()
            #expect(!shouldCapture(tracker, at: start + .seconds(5)))

            // A save that fails after its reference was committed must not leave the screen counted as captured.
            tracker.forgetReferences()
            #expect(shouldCapture(tracker, at: start + .seconds(5)))
        }

        @Test
        func idlePeriodWithoutFramesDoesNotCountAsMoving() {
            var tracker = capturedTracker()
            // No frames arrive while the display is idle, then the whole screen changes at once.
            let changedAt = start + maximumInterval + .seconds(10)
            ingest(&tracker, fingerprint { _, _ in 200 }, at: changedAt)

            #expect(!shouldCapture(tracker, at: changedAt))
            #expect(shouldCapture(tracker, at: changedAt + ScreenshotSettleTracker.settleDuration))
        }

        @Test
        func captureWaitsUntilTheWholeChangeSettles() {
            var tracker = capturedTracker()
            let firstChangeAt = start + .seconds(5)
            ingest(&tracker, fingerprint { x, y in y < 12 && x < 32 ? 200 : 0 }, at: firstChangeAt)
            let nextChangeAt = firstChangeAt + .milliseconds(800)
            ingest(&tracker, fingerprint { x, y in (y < 12 && x < 32) || (12 ..< 24).contains(y) ? 200 : 0 }, at: nextChangeAt)

            // The first part has settled, but a third of the screen is still moving.
            #expect(!shouldCapture(tracker, at: firstChangeAt + ScreenshotSettleTracker.settleDuration))
            let nextSettledAt = nextChangeAt + ScreenshotSettleTracker.settleDuration
            #expect(!shouldCapture(tracker, at: nextSettledAt - .milliseconds(1)))
            #expect(shouldCapture(tracker, at: nextSettledAt))
        }

        @Test
        func scrollIsCapturedOnlyAfterItStops() {
            // A shared document scrolls above sporadically moving camera tiles, as in a meeting window.
            var cameras = CameraTiles(rows: 24 ..< 36)
            var scroll = 0
            let captures = captureTimes(through: .seconds(20)) { elapsed in
                if elapsed > .seconds(5), elapsed <= .seconds(10) {
                    scroll += 1
                }
                cameras.advance()
                return fingerprint { x, y in
                    y < 20 && x < 48 ? textLine(x, y + scroll) : cameras.pixel(x, y)
                }
            }

            // The first frame, then the scroll's final position once it has been still for the settle duration.
            #expect(captures == [.zero, .seconds(11)])
        }

        @Test
        func sporadicCameraMotionDoesNotAddUp() {
            var cameras = CameraTiles(rows: 0 ..< 36)
            let captures = captureTimes(through: .seconds(60)) { _ in
                cameras.advance()
                return fingerprint { x, y in cameras.pixel(x, y) }
            }

            // A camera gallery is checked only at the interval, like a mostly moving screen.
            #expect(captures.first == .zero)
            #expect(zip(captures, captures.dropFirst()).allSatisfy { $1 - $0 >= maximumInterval })
        }

        @Test
        func gradualChangesWaitForTheInterval() {
            var tracker = capturedTracker()
            // Each step changes a different 6% of the screen: none is a threshold-sized change by itself.
            for step in 0 ..< 5 {
                let limit = 2 * (step + 1)
                ingest(&tracker, fingerprint { _, y in y < limit ? 200 : 0 }, at: start + .seconds(1 + 2 * step))
            }

            #expect(!shouldCapture(tracker, at: start + .seconds(12)))
            #expect(tracker.checkDeadline(after: start + .seconds(12), interval: maximumInterval, isAdaptive: true)
                == start + maximumInterval)
            #expect(shouldCapture(tracker, at: start + maximumInterval))
        }

        @Test
        func cameraAreaIsExcludedFromChangeRatio() {
            var tracker = capturedTracker()
            // Video changing this much at once is told apart from a scroll only once it has kept moving for a while.
            let warmUp = 42
            for step in 1 ... warmUp {
                let now = at(step: step)
                ingest(&tracker, fingerprint { _, y in y >= 24 ? flicker(step) : 0 }, at: now)
                #expect(!shouldCapture(tracker, at: now))
            }
            tracker.commit(tracker.captureReference(at: at(step: warmUp), isAdaptive: true))

            // 17% of the whole screen, but more than 20% of the still part.
            let slide: (Int, Int) -> UInt8 = { x, y in y < 8 && x < 48 ? 200 : 0 }
            for step in warmUp + 1 ... warmUp + 3 {
                ingest(&tracker, fingerprint { x, y in y >= 24 ? flicker(step) : slide(x, y) }, at: at(step: step))
            }
            #expect(shouldCapture(tracker, at: at(step: warmUp + 3)))
        }

        @Test
        func cameraAreaNeverTriggersFallback() {
            var tracker = capturedTracker()
            for step in 1 ... 60 {
                let now = at(step: step)
                ingest(&tracker, fingerprint { _, y in y >= 24 ? flicker(step) : 0 }, at: now)
                #expect(!shouldCapture(tracker, at: now))
            }
        }

        @Test
        func mostlyMovingScreenFallsBackToMaximumInterval() {
            var tracker = capturedTracker()
            let steps = Int(maximumInterval / .milliseconds(500))
            for step in 1 ..< steps {
                let now = at(step: step)
                ingest(&tracker, fingerprint { _, y in y < 24 ? flicker(step) : 0 }, at: now)
                #expect(!shouldCapture(tracker, at: now))
            }

            ingest(&tracker, fingerprint { _, y in y < 24 ? flicker(steps) : 0 }, at: at(step: steps))
            #expect(shouldCapture(tracker, at: at(step: steps)))
        }

        @Test
        func smallStillAreaOverMovingScreenIsNotAFullChange() {
            var tracker = capturedTracker()
            let subtitle: (Int, Int) -> UInt8 = { x, y in y == 34 && (20 ..< 44).contains(x) ? 200 : 0 }
            for step in 1 ... 12 {
                let now = at(step: step)
                ingest(&tracker, fingerprint { x, y in y < 30 ? flicker(step) : subtitle(x, y) }, at: now)
                #expect(!shouldCapture(tracker, at: now))
            }
        }

        @Test
        func slowFadeIsNotTreatedAsSettled() {
            var tracker = capturedTracker()
            // Each frame moves less than the per-pixel difference, but the fade keeps accumulating.
            for step in 1 ... 20 {
                let now = at(step: step)
                ingest(&tracker, fingerprint { _, _ in UInt8(step * 5) }, at: now)
                #expect(!shouldCapture(tracker, at: now))
            }

            #expect(shouldCapture(tracker, at: at(step: 20) + .seconds(1)))
        }

        private func ingest(
            _ tracker: inout ScreenshotSettleTracker,
            _ fingerprint: ScreenshotFingerprint,
            at now: ContinuousClock.Instant,
            threshold: Double? = nil
        ) {
            tracker.ingest(fingerprint, at: now, changeThresholdRatio: threshold ?? self.threshold)
        }

        private func shouldCapture(
            _ tracker: ScreenshotSettleTracker,
            at now: ContinuousClock.Instant,
            threshold: Double? = nil,
            isAdaptive: Bool = true
        ) -> Bool {
            tracker.shouldCapture(
                at: now,
                interval: maximumInterval,
                isAdaptive: isAdaptive,
                changeThresholdRatio: threshold ?? self.threshold
            )
        }

        private func capturedTracker() -> ScreenshotSettleTracker {
            var tracker = ScreenshotSettleTracker()
            ingest(&tracker, fingerprint { _, _ in 0 }, at: start)
            tracker.commit(tracker.captureReference(at: start, isAdaptive: true))
            return tracker
        }

        private func at(step: Int) -> ContinuousClock.Instant {
            start + .milliseconds(500 * step)
        }

        /// A quarter of the screen far from the camera rows used below.
        private func isSlide(_ x: Int, _ y: Int) -> Bool {
            y < 12 && x < 48
        }

        /// A value that flips every frame like camera video.
        private func flicker(_ step: Int) -> UInt8 {
            step.isMultiple(of: 2) ? 100 : 200
        }

        /// Feeds a 4 fps stream at the default 5% threshold, committing each capture, and returns when they happened.
        private func captureTimes(
            through duration: Duration,
            frame: (_ elapsed: Duration) -> ScreenshotFingerprint
        ) -> [Duration] {
            var tracker = ScreenshotSettleTracker()
            var captures: [Duration] = []
            for step in 0 ... Int(duration / .milliseconds(250)) {
                let elapsed = Duration.milliseconds(250 * step)
                let now = start + elapsed
                ingest(&tracker, frame(elapsed), at: now, threshold: 0.05)
                if shouldCapture(tracker, at: now, threshold: 0.05) {
                    captures.append(elapsed)
                    tracker.commit(tracker.captureReference(at: now, isAdaptive: true))
                }
            }
            return captures
        }

        /// Text lines of varying length with a blank line between paragraphs.
        private func textLine(_ x: Int, _ line: Int) -> UInt8 {
            !line.isMultiple(of: 3) && x < 6 + (line * 7919) % 40 ? 90 : 240
        }

        private func fingerprint(_ pixel: (_ x: Int, _ y: Int) -> UInt8) -> ScreenshotFingerprint {
            let width = 64
            let height = 36
            return ScreenshotFingerprint(
                width: width,
                height: height,
                pixels: (0 ..< width * height).map { pixel($0 % width, $0 / width) }
            )
        }
    }

    /// Eight camera tiles in which a few cells shift now and then, like people sitting in front of their cameras.
    private struct CameraTiles {
        private let rows: Range<Int>
        private var pixels: [UInt8]
        private var seed: UInt64 = 42

        init(rows: Range<Int>) {
            self.rows = rows
            pixels = (0 ..< 64 * 36).map { UInt8(60 + ($0 * 37) % 120) }
        }

        mutating func advance() {
            let tileHeight = rows.count / 2
            for tile in 0 ..< 8 where random() < 0.15 {
                let x = (tile % 4) * 16 + 4 + Int(random() * 8)
                let y = rows.lowerBound + (tile / 4) * tileHeight + 1 + Int(random() * Double(max(1, tileHeight - 4)))
                let shift = (random() < 0.5 ? -1 : 1) * (15 + Int(random() * 25))
                for row in y ..< min(rows.upperBound, y + 3) {
                    for column in x ..< x + 3 {
                        pixels[row * 64 + column] = UInt8(clamping: Int(pixels[row * 64 + column]) + shift)
                    }
                }
            }
        }

        func pixel(_ x: Int, _ y: Int) -> UInt8 {
            pixels[y * 64 + x]
        }

        private mutating func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
    }
#endif
