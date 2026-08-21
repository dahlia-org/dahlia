import CoreGraphics
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
    }

    private enum TestImageError: Error {
        case contextUnavailable
        case imageUnavailable
    }
#endif
