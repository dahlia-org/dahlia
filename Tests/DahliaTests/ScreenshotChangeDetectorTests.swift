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
#endif
