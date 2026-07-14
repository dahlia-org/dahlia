import CoreGraphics
import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

struct ScreenshotImageLoaderTests {
    @Test
    func downsampledImageRespectsPixelLimit() async throws {
        let image = try #require(makeImage(width: 200, height: 100))
        let data = try #require(ImageEncoder.encode(image, quality: 0.8))
        let loader = ScreenshotImageLoader(cacheCostLimit: 1_024 * 1_024)

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
        let loader = ScreenshotImageLoader(cacheCostLimit: 1_024 * 1_024)
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
    func originalImageKeepsSourceResolution() async throws {
        let image = try #require(makeImage(width: 320, height: 180))
        let data = try #require(ImageEncoder.encode(image, quality: 0.8))
        let loader = ScreenshotImageLoader(cacheCostLimit: 1_024 * 1_024)

        let decoded = await loader.originalImage(data: data)

        let result = try #require(decoded)
        #expect(result.width == 320)
        #expect(result.height == 180)
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
