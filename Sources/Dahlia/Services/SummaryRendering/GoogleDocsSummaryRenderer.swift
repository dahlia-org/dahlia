import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GoogleDocsSummaryRenderer {
    struct RenderedDocument: Equatable {
        let data: Data
        let mimeType: String
    }

    private struct PreparedImage {
        let data: Data
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private static let documentWidthTwips = 9000
    private static let imageMaxLongEdge = 1600

    static func render(
        document: SummaryDocument,
        context: SummaryRenderContext,
        actionItemsHeading: String,
        imageUnavailableText: String
    ) -> RenderedDocument {
        let screenshotsByID = Dictionary(uniqueKeysWithValues: context.screenshots.map { ($0.id, $0) })
        var imageCache: [UUID: PreparedImage] = [:]
        var body = ""

        if let title = normalizedText(document.title) {
            body += heading(title, level: 1)
        }

        for section in document.sections {
            if let sectionHeading = normalizedText(section.heading) {
                body += heading(sectionHeading, level: 2)
            }
            for block in section.blocks {
                body += renderBlock(
                    block,
                    screenshotsByID: screenshotsByID,
                    imageCache: &imageCache,
                    imageUnavailableText: imageUnavailableText
                )
            }
        }

        let actionItems = document.actionItems.compactMap { item -> String? in
            guard let title = normalizedText(item.title) else { return nil }
            if let assignee = normalizedText(item.assignee) {
                return "\(title) (\(assignee))"
            }
            return title
        }
        if !actionItems.isEmpty {
            body += heading(actionItemsHeading, level: 2)
            body += bulletedList(actionItems, symbol: "☐")
        }

        let rtf = """
        {\\rtf1\\ansi\\ansicpg1252\\deff0\\uc0
        {\\fonttbl{\\f0\\fswiss Helvetica;}{\\f1\\fmodern Menlo;}}
        \\viewkind4
        \(body)}
        """
        return RenderedDocument(data: Data(rtf.utf8), mimeType: "application/rtf")
    }

    private static func renderBlock(
        _ block: SummaryBlock,
        screenshotsByID: [UUID: MeetingScreenshotRecord],
        imageCache: inout [UUID: PreparedImage],
        imageUnavailableText: String
    ) -> String {
        switch block.content {
        case let .paragraph(text):
            return paragraph(text.text)
        case let .bulletedList(items):
            return bulletedList(items.map(\.text), symbol: "•")
        case let .numberedList(items):
            return numberedList(items.map(\.text))
        case let .checklist(items):
            return checklist(items)
        case let .quote(text):
            return quote(text.text)
        case let .code(_, content):
            return codeBlock(content.text)
        case let .image(screenshotID, caption):
            return imageBlock(
                screenshotID: screenshotID,
                caption: caption.text,
                screenshotsByID: screenshotsByID,
                imageCache: &imageCache,
                imageUnavailableText: imageUnavailableText
            )
        case let .heading(level, content):
            guard let text = normalizedText(content.text) else { return "" }
            return heading(text, level: min(max(level, 3), 6))
        case let .table(headers, rows):
            return table(headers: headers, rows: rows)
        }
    }

    private static func heading(_ text: String, level: Int) -> String {
        let fontSize = switch level {
        case 1: 36
        case 2: 30
        case 3: 26
        default: 22
        }
        let spaceBefore = level == 1 ? 0 : 240
        return "\\pard\\plain\\keepn\\sb\(spaceBefore)\\sa160\\b\\fs\(fontSize) \(inlineRTF(text))\\par\n"
    }

    private static func paragraph(_ text: String) -> String {
        guard let text = normalizedText(text) else { return "" }
        return "\\pard\\plain\\sa160\\fs22 \(inlineRTF(text))\\par\n"
    }

    private static func bulletedList(_ items: [String], symbol: String) -> String {
        items.compactMap { item -> String? in
            guard let item = normalizedText(item) else { return nil }
            return listItem(item, marker: symbol)
        }
        .joined()
    }

    private static func numberedList(_ items: [String]) -> String {
        items.enumerated().compactMap { index, item -> String? in
            guard let item = normalizedText(item) else { return nil }
            return listItem(item, marker: "\(index + 1).")
        }
        .joined()
    }

    private static func checklist(_ items: [SummaryBlock.ChecklistItem]) -> String {
        items.compactMap { item -> String? in
            guard let text = normalizedText(item.text.text) else { return nil }
            return listItem(text, marker: item.checked ? "☑" : "☐")
        }
        .joined()
    }

    private static func listItem(_ text: String, marker: String) -> String {
        "\\pard\\plain\\li720\\fi-360\\tx720\\sa80\\fs22 \(escapedRTF(marker))\\tab \(inlineRTF(text))\\par\n"
    }

    private static func quote(_ text: String) -> String {
        guard let text = normalizedText(text) else { return "" }
        return "\\pard\\plain\\li720\\ri360\\sa160\\i\\fs22 \(inlineRTF(text))\\par\n"
    }

    private static func codeBlock(_ text: String) -> String {
        guard let text = text.nilIfBlank else { return "" }
        return "\\pard\\plain\\li360\\ri360\\sa160\\f1\\fs20 \(escapedRTF(text))\\par\n"
    }

    private static func imageBlock(
        screenshotID: UUID,
        caption: String,
        screenshotsByID: [UUID: MeetingScreenshotRecord],
        imageCache: inout [UUID: PreparedImage],
        imageUnavailableText: String
    ) -> String {
        let image: PreparedImage
        if let cached = imageCache[screenshotID] {
            image = cached
        } else {
            guard let screenshot = screenshotsByID[screenshotID],
                  let prepared = prepareImage(screenshot.imageData) else {
                return unavailableImageBlock(caption: caption, message: imageUnavailableText)
            }
            imageCache[screenshotID] = prepared
            image = prepared
        }

        let naturalWidth = max(image.pixelWidth * 15, 1)
        let width = min(naturalWidth, documentWidthTwips)
        let height = max(Int((Double(width) * Double(image.pixelHeight) / Double(image.pixelWidth)).rounded()), 1)
        let imageRTF = """
        \\pard\\plain\\qc\\sa120
        {\\pict\\jpegblip\\picw\(image.pixelWidth)\\pich\(image.pixelHeight)\\picwgoal\(width)\\pichgoal\(height)
        \(hexEncoded(image.data))}
        \\par
        """

        guard let caption = normalizedText(caption) else { return imageRTF }
        return imageRTF + "\\pard\\plain\\qc\\sa160\\i\\fs20 \(inlineRTF(caption))\\par\n"
    }

    private static func unavailableImageBlock(caption: String, message: String) -> String {
        let text = if let caption = normalizedText(caption) {
            "\(message): \(caption)"
        } else {
            message
        }
        return "\\pard\\plain\\qc\\sa160\\i\\fs20 \(inlineRTF(text))\\par\n"
    }

    private static func table(headers: [SummaryText], rows: [[SummaryText]]) -> String {
        guard !headers.isEmpty else { return "" }
        let header = headers.compactMap { normalizedText($0.text) }.map(inlineRTF).joined(separator: "\\tab ")
        let renderedHeader = "\\pard\\plain\\sa80\\b\\fs22 \(header)\\par\n"
        let renderedRows: String = rows.map { row in
            let cells = row.compactMap { normalizedText($0.text) }.map(inlineRTF).joined(separator: "\\tab ")
            return "\\pard\\plain\\sa80\\fs22 \(cells)\\par\n"
        }
        .joined()
        return renderedHeader + renderedRows
    }

    private static func inlineRTF(_ markdown: String) -> String {
        let normalized = markdown.replacing(#/!\[([^\]]*)\]\([^)]+\)/#) { match in
            String(match.1)
        }
        guard let attributed = try? AttributedString(
            markdown: normalized,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return escapedRTF(normalized)
        }

        return attributed.runs.map { run in
            let text = escapedRTF(String(attributed[run.range].characters))
            var controls: [String] = []
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { controls.append("\\f1") }
                if intent.contains(.stronglyEmphasized) { controls.append("\\b") }
                if intent.contains(.emphasized) { controls.append("\\i") }
                if intent.contains(.strikethrough) { controls.append("\\strike") }
            }

            let styled = if controls.isEmpty {
                "{\(text)}"
            } else {
                "{\(controls.joined()) \(text)}"
            }
            guard let link = run.link, isSafeLink(link) else { return styled }
            let target = escapedFieldInstruction(link.absoluteString)
            return "{\\field{\\*\\fldinst HYPERLINK \"\(target)\"}{\\fldrslt \(styled)}}"
        }
        .joined()
    }

    private static func normalizedText(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private static func escapedRTF(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for codeUnit in text.utf16 {
            switch codeUnit {
            case 9:
                result += "\\tab "
            case 10:
                result += "\\line "
            case 13:
                continue
            case 92, 123, 125:
                if let scalar = UnicodeScalar(codeUnit) {
                    result += "\\"
                    result.unicodeScalars.append(scalar)
                }
            case 32 ... 126:
                if let scalar = UnicodeScalar(codeUnit) {
                    result.unicodeScalars.append(scalar)
                }
            default:
                result += "\\u\(Int(Int16(bitPattern: codeUnit))) "
            }
        }
        return result
    }

    private static func escapedFieldInstruction(_ text: String) -> String {
        text
            .replacing("\\", with: "\\\\")
            .replacing("\"", with: "\\\"")
            .replacing("{", with: "\\{")
            .replacing("}", with: "\\}")
    }

    private static func isSafeLink(_ link: URL) -> Bool {
        guard let scheme = link.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }

    private static func prepareImage(_ data: Data) -> PreparedImage? {
        guard let image = CGImageDecoder.decode(data, maxPixelSize: imageMaxLongEdge) else { return nil }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.78,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return PreparedImage(
            data: encoded as Data,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    private static func hexEncoded(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(data.count * 2)
        for byte in data {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0F)])
        }
        return String(bytes: encoded, encoding: .utf8) ?? ""
    }
}
