import CoreGraphics
import Foundation
@testable import Dahlia
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    struct ScreenshotImageLoaderTests {
        @Test
        func downsampledImageRespectsPixelLimit() async throws {
            let image = try #require(makeImage(width: 200, height: 100))
            let data = try #require(ImageEncoder.encode(image, quality: 0.8))
            let loader = ScreenshotImageLoader(cacheCostLimit: 1024 * 1024)

            let decoded = await loader.image(
                screenshotID: UUID.v7(),
                data: data,
                maxPixelSize: 64
            )

            let result = try #require(decoded)
            #expect(max(result.width, result.height) <= 64)
        }

        @Test
        func invalidImageDataFailsWithoutBlockingFutureLoads() async throws {
            let loader = ScreenshotImageLoader(cacheCostLimit: 1024 * 1024)
            let invalid = await loader.image(
                screenshotID: UUID.v7(),
                data: Data("not an image".utf8),
                maxPixelSize: 64
            )
            #expect(invalid == nil)

            let image = try #require(makeImage(width: 32, height: 32))
            let data = try #require(ImageEncoder.encode(image, quality: 0.8))
            let valid = await loader.image(
                screenshotID: UUID.v7(),
                data: data,
                maxPixelSize: 64
            )
            #expect(valid != nil)
        }

        @Test
        func unloadingReleasesLoadedImageState() async throws {
            let image = try #require(makeImage(width: 32, height: 32))
            let data = try #require(ImageEncoder.encode(image, quality: 0.8))
            let model = ScreenshotImageLoadModel()

            await model.load(
                screenshotID: UUID.v7(),
                data: data,
                maxPixelSize: 32
            )
            guard case .loaded = model.state else {
                Issue.record("Expected the image to finish loading")
                return
            }

            model.unload()

            guard case .idle = model.state else {
                Issue.record("Expected unload to release the loaded image")
                return
            }
        }

        private func makeImage(width: Int, height: Int) -> CGImage? {
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
    }
#endif
