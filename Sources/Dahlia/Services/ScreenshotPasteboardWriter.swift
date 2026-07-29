import AppKit
import DahliaRuntimeSupport
import Foundation
import UniformTypeIdentifiers

private actor ScreenshotPasteboardImageValidator {
    func detectedMIMEType(for data: Data) -> String? {
        ImageEncoder.mimeType(for: data)
    }
}

@MainActor
enum ScreenshotPasteboardWriter {
    private static let validator = ScreenshotPasteboardImageValidator()

    @discardableResult
    static func write(
        _ screenshot: MeetingScreenshotRecord,
        to pasteboard: NSPasteboard = .general
    ) async -> Bool {
        guard !screenshot.imageData.isEmpty,
              let declaredContentType = contentType(for: screenshot.mimeType),
              let detectedMIMEType = await validator.detectedMIMEType(for: screenshot.imageData),
              let detectedContentType = contentType(for: detectedMIMEType),
              declaredContentType == detectedContentType else { return false }

        let item = NSPasteboardItem()
        guard item.setData(
            screenshot.imageData,
            forType: NSPasteboard.PasteboardType(detectedContentType.identifier)
        ) else { return false }

        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    private static func contentType(for mimeType: String) -> UTType? {
        switch mimeType.lowercased() {
        case "image/png":
            .png
        case "image/jpeg", "image/jpg":
            .jpeg
        case "image/gif":
            .gif
        case "image/tiff":
            .tiff
        case "image/webp":
            .webP
        default:
            nil
        }
    }
}
