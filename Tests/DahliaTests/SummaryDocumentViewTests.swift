#if canImport(Testing)
import CoreGraphics
import Foundation
import Testing
@testable import Dahlia

@MainActor
struct SummaryDocumentViewTests {
    @Test
    func screenshotActivationForwardsIdentifierAndPreviewOnce() throws {
        let screenshotID = UUID.v7()
        let image = try #require(makeImage())
        var openedScreenshotID: UUID?
        var openedImage: CGImage?
        var openCount = 0
        let view = SummaryScreenshotImageView(
            screenshotID: screenshotID,
            data: Data(),
            accessibilityLabel: "Enlarge screenshot"
        ) { id, previewImage in
            openedScreenshotID = id
            openedImage = previewImage
            openCount += 1
        }

        view.activate(image)

        #expect(openedScreenshotID == screenshotID)
        #expect(openedImage === image)
        #expect(openCount == 1)
    }

    private func makeImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context?.makeImage()
    }
}
#endif
