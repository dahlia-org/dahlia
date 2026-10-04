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
            tracker.ingest(fingerprint { _ in 0 }, at: start)

            #expect(shouldCapture(tracker, at: start))
        }

        @Test
        func changeIsCapturedOnlyAfterItStopsMoving() throws {
            var tracker = capturedTracker()
            let changedAt = start + .seconds(5)
            tracker.ingest(fingerprint { $0 < 30 ? 200 : 0 }, at: changedAt)

            #expect(!shouldCapture(tracker, at: changedAt))
            let deadline = try #require(tracker.settleDeadline(after: changedAt))
            #expect(deadline == changedAt + ScreenshotSettleTracker.settleDuration)
            #expect(shouldCapture(tracker, at: deadline))

            tracker.commit(tracker.captureReference(at: deadline), isSaved: true)
            #expect(!shouldCapture(tracker, at: deadline))
        }

        @Test
        func uncommittedCaptureKeepsChangePending() {
            var tracker = capturedTracker()
            let changedAt = start + .seconds(5)
            tracker.ingest(fingerprint { $0 < 30 ? 200 : 0 }, at: changedAt)
            let settledAt = changedAt + ScreenshotSettleTracker.settleDuration

            // A failed or discarded capture never commits its reference, so the change is retried.
            _ = tracker.captureReference(at: settledAt)
            #expect(shouldCapture(tracker, at: settledAt))

            tracker.commit(tracker.captureReference(at: settledAt), isSaved: true)
            #expect(!shouldCapture(tracker, at: settledAt))
        }

        @Test
        func forgottenReferencesCaptureTheUnchangedScreenAgain() {
            var tracker = capturedTracker()
            #expect(!shouldCapture(tracker, at: start + .seconds(5)))
            #expect(!shouldCapture(tracker, at: start + .seconds(5), comparedWith: .lastAttempt))

            // A save that fails after its reference was committed must not leave the screen counted as captured.
            tracker.forgetReferences()
            #expect(shouldCapture(tracker, at: start + .seconds(5)))
            #expect(shouldCapture(tracker, at: start + .seconds(5), comparedWith: .lastAttempt))
        }

        @Test
        func skippedAttemptsKeepSmallChangesAddingUpAgainstLastSave() {
            var tracker = capturedTracker()
            // Each step changes 2% of the screen: enough for the 1% gate, not for the 5% save threshold.
            var changed = 0
            for step in 1 ... 3 {
                changed += 2
                let changedAt = start + .seconds(5 * step)
                let limit = changed
                tracker.ingest(fingerprint { $0 < limit ? 200 : 0 }, at: changedAt)
                let settledAt = changedAt + ScreenshotSettleTracker.settleDuration

                #expect(shouldCapture(tracker, at: settledAt, threshold: 0.01, comparedWith: .lastAttempt))
                let passesSaveThreshold = shouldCapture(tracker, at: settledAt, threshold: 0.05)
                #expect(passesSaveThreshold == (step == 3))
                tracker.commit(tracker.captureReference(at: settledAt), isSaved: passesSaveThreshold)
                // The gate does not re-trigger on the change it just checked.
                #expect(!shouldCapture(tracker, at: settledAt, threshold: 0.01, comparedWith: .lastAttempt))
            }
            #expect(!shouldCapture(tracker, at: start + .seconds(16), threshold: 0.05))
        }

        @Test
        func sharedContentGateTriggersOnceForASingleStillCellChange() {
            let gate = AutomaticScreenshotCaptureService.sharedContentGateRatio
            let blank = ScreenshotFingerprint(width: 64, height: 36, pixels: Array(repeating: 0, count: 64 * 36))
            var tracker = ScreenshotSettleTracker()
            tracker.ingest(blank, at: start)
            tracker.commit(tracker.captureReference(at: start), isSaved: true)

            // One cell is far below 1% of a full-size fingerprint, yet it may be a threshold-sized change in the crop.
            var changed = blank.pixels
            changed[0] = 200
            let changedAt = start + .seconds(5)
            tracker.ingest(ScreenshotFingerprint(width: 64, height: 36, pixels: changed), at: changedAt)
            let settledAt = changedAt + ScreenshotSettleTracker.settleDuration

            #expect(shouldCapture(tracker, at: settledAt, threshold: gate, comparedWith: .lastAttempt))
            tracker.commit(tracker.captureReference(at: settledAt), isSaved: false)
            #expect(!shouldCapture(tracker, at: settledAt, threshold: gate, comparedWith: .lastAttempt))
        }

        @Test
        func idlePeriodWithoutFramesDoesNotCountAsMoving() {
            var tracker = capturedTracker()
            // No frames arrive while the display is idle, then the whole screen changes at once.
            let changedAt = start + maximumInterval + .seconds(10)
            tracker.ingest(fingerprint { _ in 200 }, at: changedAt)

            #expect(!shouldCapture(tracker, at: changedAt))
            #expect(shouldCapture(tracker, at: changedAt + ScreenshotSettleTracker.settleDuration))
        }

        @Test
        func changeStillMovingAtCaptureIsEvaluatedAgainOnceSettled() {
            var tracker = capturedTracker()
            let firstChangeAt = start + .seconds(5)
            tracker.ingest(fingerprint { $0 < 30 ? 200 : 0 }, at: firstChangeAt)
            let nextChangeAt = firstChangeAt + .milliseconds(800)
            tracker.ingest(fingerprint { $0 < 30 || $0 >= 50 ? 200 : 0 }, at: nextChangeAt)

            let firstSettledAt = firstChangeAt + ScreenshotSettleTracker.settleDuration
            #expect(shouldCapture(tracker, at: firstSettledAt))
            tracker.commit(tracker.captureReference(at: firstSettledAt), isSaved: true)

            let nextSettledAt = nextChangeAt + ScreenshotSettleTracker.settleDuration
            #expect(!shouldCapture(tracker, at: nextSettledAt - .milliseconds(1)))
            #expect(shouldCapture(tracker, at: nextSettledAt))
        }

        @Test
        func cameraAreaIsExcludedFromChangeRatio() {
            var tracker = capturedTracker()
            for step in 1 ... 10 {
                let now = at(step: step)
                tracker.ingest(fingerprint { movingPixel($0, step: step, below: 30) }, at: now)
                #expect(!shouldCapture(tracker, at: now))
            }

            // 15% of the whole screen, but more than 20% of the still part.
            let slide: (Int) -> UInt8 = { (30 ..< 45).contains($0) ? 200 : 0 }
            for step in 11 ... 13 {
                tracker.ingest(fingerprint { max(movingPixel($0, step: step, below: 30), slide($0)) }, at: at(step: step))
            }
            #expect(shouldCapture(tracker, at: at(step: 13)))
        }

        @Test
        func cameraAreaNeverTriggersFallback() {
            var tracker = capturedTracker()
            for step in 1 ... 60 {
                let now = at(step: step)
                tracker.ingest(fingerprint { movingPixel($0, step: step, below: 30) }, at: now)
                #expect(!shouldCapture(tracker, at: now))
            }
        }

        @Test
        func mostlyMovingScreenFallsBackToMaximumInterval() {
            var tracker = capturedTracker()
            let steps = Int(maximumInterval / .milliseconds(500))
            for step in 1 ..< steps {
                let now = at(step: step)
                tracker.ingest(fingerprint { movingPixel($0, step: step, below: 60) }, at: now)
                #expect(!shouldCapture(tracker, at: now))
            }

            tracker.ingest(fingerprint { movingPixel($0, step: steps, below: 60) }, at: at(step: steps))
            #expect(shouldCapture(tracker, at: at(step: steps)))
        }

        @Test
        func smallStillAreaOverMovingScreenIsNotAFullChange() {
            var tracker = capturedTracker()
            let subtitle: (Int) -> UInt8 = { (80 ..< 88).contains($0) ? 200 : 0 }
            for step in 1 ... 6 {
                let now = at(step: step)
                tracker.ingest(fingerprint { max(movingPixel($0, step: step, below: 80), subtitle($0)) }, at: now)
                #expect(!shouldCapture(tracker, at: now))
            }
        }

        @Test
        func slowFadeIsNotTreatedAsSettled() {
            var tracker = capturedTracker()
            // Each frame moves less than the per-pixel difference, but the fade keeps accumulating.
            for step in 1 ... 20 {
                let now = at(step: step)
                tracker.ingest(fingerprint { _ in UInt8(step * 5) }, at: now)
                #expect(!shouldCapture(tracker, at: now))
            }

            #expect(shouldCapture(tracker, at: at(step: 20) + .seconds(1)))
        }

        private func shouldCapture(
            _ tracker: ScreenshotSettleTracker,
            at now: ContinuousClock.Instant,
            threshold: Double? = nil,
            comparedWith baseline: ScreenshotSettleTracker.Baseline = .lastSaved
        ) -> Bool {
            tracker.shouldCapture(
                at: now,
                maximumInterval: maximumInterval,
                changeThresholdRatio: threshold ?? self.threshold,
                comparedWith: baseline
            )
        }

        private func capturedTracker() -> ScreenshotSettleTracker {
            var tracker = ScreenshotSettleTracker()
            tracker.ingest(fingerprint { _ in 0 }, at: start)
            tracker.commit(tracker.captureReference(at: start), isSaved: true)
            return tracker
        }

        private func at(step: Int) -> ContinuousClock.Instant {
            start + .milliseconds(500 * step)
        }

        /// Pixels below `limit` flicker like camera video; the rest stay still.
        private func movingPixel(_ index: Int, step: Int, below limit: Int) -> UInt8 {
            index < limit ? UInt8(step.isMultiple(of: 2) ? 100 : 200) : 0
        }

        private func fingerprint(_ pixel: (Int) -> UInt8) -> ScreenshotFingerprint {
            ScreenshotFingerprint(width: 10, height: 10, pixels: (0 ..< 100).map(pixel))
        }
    }
#endif
