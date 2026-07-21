#if canImport(Testing)
import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Dahlia

@MainActor
struct CodexChatPasteboardImageReaderTests {
    @Test
    func readsOnePreferredRepresentationPerImage() {
        let pasteboard = makePasteboard()
        let firstPNG = Data([1, 2, 3])
        let firstTIFF = Data([4, 5, 6])
        let secondTIFF = Data([7, 8, 9])
        let firstItem = NSPasteboardItem()
        firstItem.setData(firstTIFF, forType: type(for: .tiff))
        firstItem.setData(firstPNG, forType: type(for: .png))
        let secondItem = NSPasteboardItem()
        secondItem.setData(secondTIFF, forType: type(for: .tiff))
        pasteboard.writeObjects([firstItem, secondItem])

        #expect(CodexChatPasteboardImageReader.imageData(from: pasteboard) == [firstPNG, secondTIFF])
    }

    @Test
    func ignoresTextOnlyPasteboardContents() {
        let pasteboard = makePasteboard()
        pasteboard.setString("Keep normal text paste working", forType: .string)

        #expect(CodexChatPasteboardImageReader.imageData(from: pasteboard).isEmpty)
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("CodexChatPasteboardImageReaderTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func type(for contentType: UTType) -> NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(contentType.identifier)
    }
}
#endif
