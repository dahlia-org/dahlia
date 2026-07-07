import CoreGraphics
import Foundation

struct ScreenshotFingerprint: Equatable {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

enum ScreenshotChangeDetector {
    private static let fingerprintWidth = 64
    private static let fingerprintHeight = 36
    private static let significantAverageDifference = 0.08
    private static let significantChangedPixelRatio = 0.20
    private static let changedPixelThreshold = 24

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

    static func isSignificantlyDifferent(_ lhs: ScreenshotFingerprint, _ rhs: ScreenshotFingerprint) -> Bool {
        guard lhs.width == rhs.width,
              lhs.height == rhs.height,
              lhs.pixels.count == rhs.pixels.count,
              !lhs.pixels.isEmpty
        else {
            return true
        }

        var totalDifference = 0
        var changedPixelCount = 0

        for index in lhs.pixels.indices {
            let difference = abs(Int(lhs.pixels[index]) - Int(rhs.pixels[index]))
            totalDifference += difference
            if difference >= changedPixelThreshold {
                changedPixelCount += 1
            }
        }

        let pixelCount = lhs.pixels.count
        let averageDifference = Double(totalDifference) / Double(pixelCount) / 255.0
        let changedPixelRatio = Double(changedPixelCount) / Double(pixelCount)

        return averageDifference >= significantAverageDifference
            || changedPixelRatio >= significantChangedPixelRatio
    }
}
