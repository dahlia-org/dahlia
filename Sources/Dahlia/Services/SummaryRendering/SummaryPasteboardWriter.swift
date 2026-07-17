import AppKit

enum SummaryPasteboardWriter {
    @MainActor
    @discardableResult
    static func write(_ content: SummaryShareContent, to pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(content.html, forType: .html),
              item.setString(content.markdown, forType: .string) else { return false }

        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
