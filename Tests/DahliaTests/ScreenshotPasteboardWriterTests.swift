#if canImport(Testing)
import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Dahlia

@MainActor
struct ScreenshotPasteboardWriterTests {
    @Test(arguments: [
        "image/png",
        "image/jpeg",
    ])
    func writesOriginalDataUsingTheStoredImageType(mimeType: String) async throws {
        let pasteboard = makePasteboard()
        let fileType: NSBitmapImageRep.FileType = mimeType == "image/png" ? .png : .jpeg
        let contentType: UTType = mimeType == "image/png" ? .png : .jpeg
        let imageData = try #require(TestScreenshotImageFixture.data(using: fileType))
        let screenshot = makeScreenshot(data: imageData, mimeType: mimeType)

        #expect(await ScreenshotPasteboardWriter.write(screenshot, to: pasteboard))

        let item = try #require(pasteboard.pasteboardItems?.first)
        let pasteboardType = NSPasteboard.PasteboardType(contentType.identifier)
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(item.data(forType: pasteboardType) == screenshot.imageData)
    }

    @Test
    func successfulWriteReplacesExistingPasteboardContents() async throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("old value", forType: .string)
        let imageData = try #require(TestScreenshotImageFixture.data(using: .png))
        let screenshot = makeScreenshot(data: imageData, mimeType: "image/png")

        #expect(await ScreenshotPasteboardWriter.write(screenshot, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test
    func corruptImageDataDoesNotReplaceExistingPasteboardContents() async {
        let pasteboard = makePasteboard()
        pasteboard.setString("keep me", forType: .string)
        let screenshot = makeScreenshot(data: Data([1, 2, 3]), mimeType: "image/png")

        let didWrite = await ScreenshotPasteboardWriter.write(screenshot, to: pasteboard)
        #expect(!didWrite)
        #expect(pasteboard.string(forType: .string) == "keep me")
    }

    @Test
    func mismatchedMIMETypeDoesNotReplaceExistingPasteboardContents() async throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("keep me", forType: .string)
        let imageData = try #require(TestScreenshotImageFixture.data(using: .png))
        let screenshot = makeScreenshot(data: imageData, mimeType: "image/jpeg")

        let didWrite = await ScreenshotPasteboardWriter.write(screenshot, to: pasteboard)
        #expect(!didWrite)
        #expect(pasteboard.string(forType: .string) == "keep me")
    }

    @Test
    func unsupportedMIMETypeDoesNotReplaceExistingPasteboardContents() async throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("keep me", forType: .string)
        let imageData = try #require(TestScreenshotImageFixture.data(using: .png))
        let screenshot = makeScreenshot(data: imageData, mimeType: "application/octet-stream")

        let didWrite = await ScreenshotPasteboardWriter.write(screenshot, to: pasteboard)
        #expect(!didWrite)
        #expect(pasteboard.string(forType: .string) == "keep me")
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("ScreenshotPasteboardWriterTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func makeScreenshot(data: Data, mimeType: String) -> MeetingScreenshotRecord {
        MeetingScreenshotRecord(
            id: .v7(),
            meetingId: .v7(),
            capturedAt: .now,
            imageData: data,
            mimeType: mimeType
        )
    }
}
#endif
