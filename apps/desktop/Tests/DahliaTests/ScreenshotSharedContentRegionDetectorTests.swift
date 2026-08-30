import CoreGraphics
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct ScreenshotSharedContentRegionDetectorTests {
        @Test
        func convertsVisionCoordinatesToImageCoordinates() {
            let region = ScreenshotSharedContentRegionDetector.region(
                from: [candidate(x: 0.1, y: 0.2, width: 0.8, height: 0.6)],
                imageSize: CGSize(width: 1000, height: 1000)
            )

            #expect(region == CGRect(x: 100, y: 200, width: 800, height: 600))
        }

        @Test(arguments: [
            CGRect(x: 0.05, y: 0.095, width: 0.90, height: 0.81),
            CGRect(x: 0.125, y: 0.05, width: 0.75, height: 0.90),
        ])
        func acceptsDominantSlideAspectRatios(_ boundingBox: CGRect) {
            let region = ScreenshotSharedContentRegionDetector.region(
                from: [ScreenshotSharedContentCandidate(boundingBox: boundingBox, confidence: 0.9)],
                imageSize: CGSize(width: 1600, height: 1000)
            )

            #expect(region != nil)
        }

        @Test
        func rejectsEquallyDominantRectangles() {
            let region = ScreenshotSharedContentRegionDetector.region(
                from: [
                    candidate(x: 0.05, y: 0.095, width: 0.90, height: 0.81),
                    candidate(x: 0.09, y: 0.131, width: 0.82, height: 0.738),
                ],
                imageSize: CGSize(width: 1600, height: 1000)
            )

            #expect(region == nil)
        }

        @Test(arguments: [
            ScreenshotSharedContentCandidate(
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.3),
                confidence: 0.9
            ),
            ScreenshotSharedContentCandidate(
                boundingBox: CGRect(x: 0.25, y: 0.05, width: 0.5, height: 0.9),
                confidence: 0.9
            ),
            ScreenshotSharedContentCandidate(
                boundingBox: CGRect(x: 0.05, y: 0.25, width: 0.9, height: 0.5),
                confidence: 0.9
            ),
            ScreenshotSharedContentCandidate(
                boundingBox: CGRect(x: -0.1, y: 0.1, width: 0.9, height: 0.6),
                confidence: 0.9
            ),
            ScreenshotSharedContentCandidate(
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.9, height: 0.6),
                confidence: 0.79
            ),
        ])
        func rejectsAmbiguousCandidates(_ candidate: ScreenshotSharedContentCandidate) {
            let region = ScreenshotSharedContentRegionDetector.region(
                from: [candidate],
                imageSize: CGSize(width: 1600, height: 1000)
            )

            #expect(region == nil)
        }

        @Test
        func blankImageFallsBackToFullImage() async throws {
            let image = try makeImage(width: 640, height: 360, sharedContentRect: nil)

            #expect(await ScreenshotSharedContentRegionDetector.region(in: image) == nil)
        }

        @Test
        func visionDetectsASingleLargeSharedRegion() async throws {
            let image = try makeImage(
                width: 640,
                height: 360,
                sharedContentRect: CGRect(x: 32, y: 54, width: 576, height: 252)
            )

            #expect(await ScreenshotSharedContentRegionDetector.region(in: image) != nil)
        }

        @Test
        func visionDetectsASingleLargeRoundedSharedRegion() async throws {
            let image = try makeImage(
                width: 640,
                height: 360,
                sharedContentRect: CGRect(x: 32, y: 54, width: 576, height: 252),
                cornerRadius: 24
            )

            #expect(await ScreenshotSharedContentRegionDetector.roundedRectangleRegion(in: image) != nil)
        }

        @Test
        func visionDetectsDarkRoundedSharedRegion() async throws {
            let image = try makeImage(
                width: 640,
                height: 360,
                sharedContentRect: CGRect(x: 32, y: 54, width: 576, height: 252),
                cornerRadius: 24,
                sharedContentIsDark: true
            )

            #expect(await ScreenshotSharedContentRegionDetector.roundedRectangleRegion(in: image) != nil)
        }

        private func candidate(
            x: CGFloat,
            y: CGFloat,
            width: CGFloat,
            height: CGFloat
        ) -> ScreenshotSharedContentCandidate {
            ScreenshotSharedContentCandidate(
                boundingBox: CGRect(x: x, y: y, width: width, height: height),
                confidence: 0.9
            )
        }

        private func makeImage(
            width: Int,
            height: Int,
            sharedContentRect: CGRect?,
            cornerRadius: CGFloat = 0,
            sharedContentIsDark: Bool = false
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
            context.setFillColor(CGColor(gray: sharedContentIsDark ? 0.95 : 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let sharedContentRect {
                context.setFillColor(CGColor(gray: sharedContentIsDark ? 0.1 : 0.95, alpha: 1))
                context.addPath(CGPath(
                    roundedRect: sharedContentRect,
                    cornerWidth: cornerRadius,
                    cornerHeight: cornerRadius,
                    transform: nil
                ))
                context.fillPath()
            }
            guard let image = context.makeImage() else { throw TestImageError.imageUnavailable }
            return image
        }
    }

    struct AutomaticScreenshotFrameProcessorTests {
        @Test
        func stabilizesNearbyStraightAndRoundedDetections() async {
            let processor = AutomaticScreenshotFrameProcessor()
            let imageSize = CGSize(width: 3200, height: 2000)
            let straightRegion = CGRect(x: 400, y: 280, width: 2590, height: 1465)
            let roundedRegion = CGRect(x: 430, y: 295, width: 2530, height: 1435)

            #expect(await processor.stabilizedSharedContentRegion(straightRegion, imageSize: imageSize) == straightRegion)
            #expect(await processor.stabilizedSharedContentRegion(roundedRegion, imageSize: imageSize) == straightRegion)
        }

        @Test
        func adoptsMaterialRegionAndResolutionChanges() async {
            let processor = AutomaticScreenshotFrameProcessor()
            let imageSize = CGSize(width: 1000, height: 800)
            let initialRegion = CGRect(x: 100, y: 100, width: 800, height: 600)
            let movedRegion = CGRect(x: 130, y: 100, width: 770, height: 600)
            let resizedRegion = CGRect(x: 260, y: 200, width: 1540, height: 1200)

            _ = await processor.stabilizedSharedContentRegion(initialRegion, imageSize: imageSize)
            #expect(await processor.stabilizedSharedContentRegion(movedRegion, imageSize: imageSize) == movedRegion)
            #expect(await processor.stabilizedSharedContentRegion(
                resizedRegion,
                imageSize: CGSize(width: 2000, height: 1600)
            ) == resizedRegion)
        }

        @Test
        func retainsRegionForOneDetectionMissThenFallsBack() async {
            let processor = AutomaticScreenshotFrameProcessor()
            let imageSize = CGSize(width: 1000, height: 800)
            let region = CGRect(x: 100, y: 100, width: 800, height: 600)

            _ = await processor.stabilizedSharedContentRegion(region, imageSize: imageSize)
            #expect(await processor.stabilizedSharedContentRegion(nil, imageSize: imageSize) == region)
            #expect(await processor.stabilizedSharedContentRegion(nil, imageSize: imageSize) == nil)

            _ = await processor.stabilizedSharedContentRegion(region, imageSize: imageSize)
            #expect(await processor.stabilizedSharedContentRegion(
                nil,
                imageSize: CGSize(width: 2000, height: 1600)
            ) == nil)
        }

        @Test
        func resetDiscardsStableRegion() async {
            let processor = AutomaticScreenshotFrameProcessor()
            let imageSize = CGSize(width: 1000, height: 800)
            let initialRegion = CGRect(x: 100, y: 100, width: 800, height: 600)
            let nearbyRegion = CGRect(x: 110, y: 105, width: 780, height: 590)

            _ = await processor.stabilizedSharedContentRegion(initialRegion, imageSize: imageSize)
            await processor.resetSharedContentRegion()

            #expect(await processor.stabilizedSharedContentRegion(nearbyRegion, imageSize: imageSize) == nearbyRegion)
        }

        @Test
        func resetDuringDetectionDiscardsStaleRegion() async {
            let imageSize = CGSize(width: 100, height: 80)
            let staleRegion = CGRect(x: 10, y: 10, width: 80, height: 60)
            let gate = SharedContentRegionDetectionGate(result: staleRegion)
            let processor = AutomaticScreenshotFrameProcessor { image in
                await gate.detect(in: image)
            }
            let task = Task {
                await processor.prepare(
                    makeFrame(width: Int(imageSize.width), height: Int(imageSize.height)),
                    detectsChangesInSharedContentOnly: true,
                    cropsToSharedContent: true
                )
            }

            await gate.waitUntilStarted()
            await processor.resetSharedContentRegion()
            await gate.resume()
            _ = await task.value

            #expect(await processor.stabilizedSharedContentRegion(nil, imageSize: imageSize) == nil)
        }

        @Test(arguments: [
            (false, false, 100, 100),
            (true, false, 60, 100),
            (false, true, 100, 60),
            (true, true, 60, 60),
        ])
        func settingsSelectFingerprintAndEncodingSources(
            detectsChangesInSharedContentOnly: Bool,
            cropsToSharedContent: Bool,
            expectedFingerprintWidth: Int,
            expectedEncodingWidth: Int
        ) throws {
            let fullImage = try makeSolidImage(width: 100, height: 80)
            let sharedContentImage = try makeSolidImage(width: 60, height: 40)

            let selected = AutomaticScreenshotFrameProcessor.selectedImages(
                fullImage: fullImage,
                sharedContentImage: sharedContentImage,
                detectsChangesInSharedContentOnly: detectsChangesInSharedContentOnly,
                cropsToSharedContent: cropsToSharedContent
            )

            #expect(selected.fingerprint.width == expectedFingerprintWidth)
            #expect(selected.encoding.width == expectedEncodingWidth)
        }

        @Test
        func missingSharedContentFallsBackToFullImage() throws {
            let fullImage = try makeSolidImage(width: 100, height: 80)
            let selected = AutomaticScreenshotFrameProcessor.selectedImages(
                fullImage: fullImage,
                sharedContentImage: nil,
                detectsChangesInSharedContentOnly: true,
                cropsToSharedContent: true
            )

            #expect(selected.fingerprint.width == fullImage.width)
            #expect(selected.encoding.width == fullImage.width)
        }

        private func makeSolidImage(width: Int, height: Int) throws -> CGImage {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = context.makeImage() else {
                throw TestImageError.imageUnavailable
            }
            return image
        }

        private func makeFrame(width: Int, height: Int) -> CopiedScreenshotFrame {
            let bytesPerRow = width * 4
            return CopiedScreenshotFrame(
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                pixels: Data(repeating: 255, count: bytesPerRow * height),
                capturedAt: Date(),
                sourcePixelDimensions: nil
            )
        }
    }

    private actor SharedContentRegionDetectionGate {
        private let result: CGRect?
        private var detectionContinuation: CheckedContinuation<CGRect?, Never>?
        private var startWaiters: [CheckedContinuation<Void, Never>] = []

        init(result: CGRect?) {
            self.result = result
        }

        func detect(in _: CGImage) async -> CGRect? {
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            return await withCheckedContinuation { continuation in
                detectionContinuation = continuation
            }
        }

        func waitUntilStarted() async {
            guard detectionContinuation == nil else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func resume() {
            detectionContinuation?.resume(returning: result)
            detectionContinuation = nil
        }
    }

    private enum TestImageError: Error {
        case contextUnavailable
        case imageUnavailable
    }
#endif
