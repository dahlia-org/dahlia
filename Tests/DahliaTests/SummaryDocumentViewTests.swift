#if canImport(Testing)
import AppKit
import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
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
        let screenshot = MeetingScreenshotRecord(
            id: screenshotID,
            meetingId: .v7(),
            capturedAt: .now,
            imageData: Data([1, 2, 3]),
            mimeType: "image/png"
        )
        let view = SummaryScreenshotImageView(
            screenshot: screenshot,
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

    @Test
    func screenshotCopyWritesOriginalDataWithoutOpeningImage() async throws {
        let pasteboard = NSPasteboard(name: .init("SummaryDocumentViewTests-\(UUID().uuidString)"))
        let imageData = try #require(TestScreenshotImageFixture.data(using: .png))
        let screenshot = MeetingScreenshotRecord(
            id: .v7(),
            meetingId: .v7(),
            capturedAt: .now,
            imageData: imageData,
            mimeType: "image/png"
        )
        var openCount = 0
        let view = SummaryScreenshotImageView(
            screenshot: screenshot,
            accessibilityLabel: "Enlarge screenshot"
        ) { _, _ in
            openCount += 1
        }

        await view.copyImage(to: pasteboard)

        let type = NSPasteboard.PasteboardType(UTType.png.identifier)
        #expect(pasteboard.data(forType: type) == screenshot.imageData)
        #expect(openCount == 0)
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
