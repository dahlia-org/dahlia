import AppKit
import UniformTypeIdentifiers

@MainActor
enum CodexChatPasteboardImageReader {
    private static let supportedTypes = [
        UTType.png,
        UTType.jpeg,
        UTType.gif,
        UTType.tiff,
        UTType.webP,
    ].map { NSPasteboard.PasteboardType($0.identifier) }

    static func imageData(from pasteboard: NSPasteboard = .general) -> [Data] {
        pasteboard.pasteboardItems?.compactMap(imageData(from:)) ?? []
    }

    private static func imageData(from item: NSPasteboardItem) -> Data? {
        supportedTypes.lazy.compactMap { item.data(forType: $0) }.first
    }
}
