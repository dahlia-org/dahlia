import DahliaRuntimeSupport
import Foundation

struct SummaryShareContent {
    let html: String
    let markdown: String
}

private enum SummaryHTMLListKind: Equatable {
    case bulleted
    case numbered

    var element: String {
        switch self {
        case .bulleted:
            "ul"
        case .numbered:
            "ol"
        }
    }
}

private struct RenderedHTMLBlock {
    let html: String
    let endsInList: Bool
}

private struct RenderedHTMLListItem {
    let html: String
    let indent: Int
    let value: Int?
}

enum SummaryShareRenderer {
    enum Destination {
        case googleDocs
        case slack
    }

    static func render(
        document: SummaryDocument,
        actionItemsHeading: String,
        for destination: Destination,
        screenshots: [MeetingScreenshotRecord] = []
    ) -> SummaryShareContent {
        let screenshotsByID = Dictionary(uniqueKeysWithValues: screenshots.map { ($0.id, $0) })
        return SummaryShareContent(
            html: renderHTML(
                document: document,
                actionItemsHeading: actionItemsHeading,
                destination: destination,
                screenshotsByID: screenshotsByID
            ),
            markdown: renderMarkdown(document: document, actionItemsHeading: actionItemsHeading)
        )
    }

    private static func renderMarkdown(document: SummaryDocument, actionItemsHeading: String) -> String {
        var chunks: [String] = []

        if let title = normalizedInlineMarkdown(document.title).nilIfBlank {
            chunks.append("# \(title)")
        }

        chunks.append(contentsOf: document.sections.compactMap(renderMarkdownSection))

        if let actionItems = renderMarkdownActionItems(document.actionItems, heading: actionItemsHeading) {
            chunks.append(actionItems)
        }

        return joinedChunks(chunks)
    }

    private static func renderMarkdownSection(_ section: SummarySection) -> String? {
        var chunks: [String] = []

        if let heading = normalizedInlineMarkdown(section.heading).nilIfBlank {
            chunks.append("## \(heading)")
        }

        chunks.append(contentsOf: section.blocks.compactMap(renderMarkdownBlock))
        return joinedChunks(chunks).nilIfBlank
    }

    private static func renderMarkdownBlock(_ block: SummaryBlock) -> String? {
        let rendered: String?
        switch block.content {
        case let .paragraph(text):
            rendered = normalizedInlineMarkdown(text.text).nilIfBlank
        case let .bulletedList(items):
            rendered = renderMarkdownBulletList(items)
        case let .numberedList(items):
            let numbers = SummaryListNumbering.numbers(for: items.map(\.indent))
            rendered = nonBlankPreservingWhitespace(zip(items, numbers)
                .compactMap { item, number in
                    let indentation = String(repeating: " ", count: item.indent * 4)
                    return normalizedInlineMarkdown(item.text.text).nilIfBlank.map { "\(indentation)\(number). \($0)" }
                }
                .joined(separator: "\n"))
        case let .checklist(items):
            rendered = nonBlankPreservingWhitespace(items.compactMap { item in
                let indentation = String(repeating: " ", count: item.indent * 4)
                return normalizedInlineMarkdown(item.text.text).nilIfBlank.map {
                    "\(indentation)- [\(item.checked ? "x" : " ")] \($0)"
                }
            }
            .joined(separator: "\n"))
        case let .quote(text):
            rendered = normalizedInlineMarkdown(text.text)
                .components(separatedBy: .newlines)
                .compactMap(\.nilIfBlank)
                .map { "> \($0)" }
                .joined(separator: "\n")
                .nilIfBlank
        case let .code(language, content):
            rendered = content.text.nilIfBlank.map { "```\(language)\n\($0)\n```" }
        case let .image(_, caption):
            rendered = normalizedInlineMarkdown(caption.text).nilIfBlank
        case let .heading(level, content):
            rendered = normalizedInlineMarkdown(content.text).nilIfBlank.map {
                "\(String(repeating: "#", count: clampedHeadingLevel(level))) \($0)"
            }
        case let .table(headers, rows):
            rendered = renderMarkdownTable(headers: headers, rows: rows)
        }
        return rendered
    }

    private static func renderMarkdownBulletList(_ items: [SummaryListItem]) -> String? {
        nonBlankPreservingWhitespace(items.compactMap { item in
            let indentation = String(repeating: " ", count: item.indent * 4)
            return normalizedInlineMarkdown(item.text.text).nilIfBlank.map { "\(indentation)- \($0)" }
        }
        .joined(separator: "\n"))
    }

    private static func renderMarkdownTable(headers: [SummaryText], rows: [[SummaryText]]) -> String? {
        guard !headers.isEmpty else { return nil }

        let header = markdownTableRow(headers)
        let separator = "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |"
        let rowLines = rows.map(markdownTableRow)
        return ([header, separator] + rowLines).joined(separator: "\n")
    }

    private static func markdownTableRow(_ cells: [SummaryText]) -> String {
        let renderedCells = cells.map { text in
            normalizedInlineMarkdown(text.text)
                .replacing("|", with: "\\|")
                .replacing("\n", with: "<br>")
        }
        return "| " + renderedCells.joined(separator: " | ") + " |"
    }

    private static func renderMarkdownActionItems(_ actionItems: [SummaryActionItem], heading: String) -> String? {
        let items = actionItems.compactMap(normalizedActionItem)

        guard !items.isEmpty else { return nil }
        let lines = items.map { item in
            let assignee = item.assignee.map { " (\($0))" } ?? ""
            return "- [ ] \(item.title)\(assignee)"
        }
        return (["## \(normalizedInlineMarkdown(heading))"] + lines).joined(separator: "\n")
    }

    private static func renderHTML(
        document: SummaryDocument,
        actionItemsHeading: String,
        destination: Destination,
        screenshotsByID: [UUID: MeetingScreenshotRecord]
    ) -> String {
        var chunks: [RenderedHTMLBlock] = []

        if let title = normalizedInlineMarkdown(document.title).nilIfBlank {
            chunks.append(RenderedHTMLBlock(
                html: renderHTMLHeading(title, level: 1, destination: destination),
                endsInList: false
            ))
        }

        chunks.append(contentsOf: document.sections.compactMap { section in
            renderHTMLSection(section, destination: destination, screenshotsByID: screenshotsByID)
        })

        if let actionItems = renderHTMLActionItems(
            document.actionItems,
            heading: actionItemsHeading,
            destination: destination
        ) {
            chunks.append(actionItems)
        }

        let body = joinHTMLBlocks(chunks, destination: destination)
        return """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"></head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func renderHTMLSection(
        _ section: SummarySection,
        destination: Destination,
        screenshotsByID: [UUID: MeetingScreenshotRecord]
    ) -> RenderedHTMLBlock? {
        var chunks: [RenderedHTMLBlock] = []

        if let heading = normalizedInlineMarkdown(section.heading).nilIfBlank {
            chunks.append(RenderedHTMLBlock(
                html: renderHTMLHeading(heading, level: 2, destination: destination),
                endsInList: false
            ))
        }

        chunks.append(contentsOf: section.blocks.compactMap { block in
            renderHTMLBlock(block, destination: destination, screenshotsByID: screenshotsByID)
        })
        guard !chunks.isEmpty else { return nil }

        let body = joinHTMLBlocks(chunks, destination: destination)
        let endsInList = chunks.last?.endsInList ?? false
        switch destination {
        case .googleDocs:
            return RenderedHTMLBlock(html: "<section>\n\(body)\n</section>", endsInList: endsInList)
        case .slack:
            return RenderedHTMLBlock(html: body, endsInList: endsInList)
        }
    }

    private static func renderHTMLBlock(
        _ block: SummaryBlock,
        destination: Destination,
        screenshotsByID: [UUID: MeetingScreenshotRecord]
    ) -> RenderedHTMLBlock? {
        let html: String?
        let endsInList: Bool

        switch block.content {
        case let .paragraph(text):
            html = htmlParagraph(text.text, destination: destination)
            endsInList = false
        case let .bulletedList(items):
            html = htmlList(items, kind: .bulleted, destination: destination)
            endsInList = true
        case let .numberedList(items):
            html = htmlList(items, kind: .numbered, destination: destination)
            endsInList = true
        case let .checklist(items):
            html = htmlChecklist(items, destination: destination)
            endsInList = true
        case let .quote(text):
            html = htmlParagraph(text.text, destination: destination).map { "<blockquote>\($0)</blockquote>" }
            endsInList = false
        case let .code(_, content):
            html = content.text.nilIfBlank.map { "<pre><code>\(escapeHTML($0))</code></pre>" }
            endsInList = false
        case let .image(screenshotID, caption):
            html = renderHTMLImage(
                screenshotID: screenshotID,
                caption: caption.text,
                destination: destination,
                screenshotsByID: screenshotsByID
            )
            endsInList = false
        case let .heading(level, content):
            html = normalizedInlineMarkdown(content.text).nilIfBlank.map {
                let headingLevel = destination == .googleDocs ? clampedHeadingLevel(level) : level
                return renderHTMLHeading($0, level: headingLevel, destination: destination)
            }
            endsInList = false
        case let .table(headers, rows):
            html = renderHTMLTable(headers: headers, rows: rows, destination: destination)
            endsInList = false
        }

        return html.map { RenderedHTMLBlock(html: $0, endsInList: endsInList) }
    }

    private static func renderHTMLImage(
        screenshotID: UUID,
        caption: String,
        destination: Destination,
        screenshotsByID: [UUID: MeetingScreenshotRecord]
    ) -> String? {
        let normalizedCaption = normalizedInlineMarkdown(caption).nilIfBlank
        let captionHTML = normalizedCaption.map { "<em>\(renderInlineHTML($0))</em>" }

        guard destination == .googleDocs else { return captionHTML }

        guard let screenshot = screenshotsByID[screenshotID],
              let encodedImage = GoogleDocsImageEncoder.encode(screenshot.imageData) else {
            return captionHTML.map { "<p>\($0)</p>" }
        }

        let source = "data:image/jpeg;base64,\(encodedImage.data.base64EncodedString())"
        let alt = normalizedCaption.map { " alt=\"\(escapeHTMLAttribute($0))\"" } ?? ""
        let image = "<img src=\"\(source)\"\(alt)>"
        guard let captionHTML else { return image }
        return "<figure>\n\(image)\n<figcaption>\(captionHTML)</figcaption>\n</figure>"
    }

    private static func htmlParagraph(_ text: String, destination: Destination) -> String? {
        guard let text = normalizedInlineMarkdown(text).nilIfBlank else { return nil }
        let html = renderInlineHTML(text)
        switch destination {
        case .googleDocs:
            return "<p>\(html)</p>"
        case .slack:
            return html
        }
    }

    private static func htmlList(
        _ items: [SummaryListItem],
        kind: SummaryHTMLListKind,
        destination: Destination
    ) -> String? {
        let visibleItems = items.compactMap { item -> (html: String, indent: Int)? in
            normalizedInlineMarkdown(item.text.text).nilIfBlank.map {
                (html: renderInlineHTML($0), indent: item.indent)
            }
        }
        guard !visibleItems.isEmpty else { return nil }

        let numbers = SummaryListNumbering.numbers(for: visibleItems.map(\.indent))
        let renderedItems = visibleItems.enumerated().map { index, item in
            RenderedHTMLListItem(
                html: item.html,
                indent: item.indent,
                value: kind == .numbered ? numbers[index] : nil
            )
        }
        return renderHTMLListItems(renderedItems, kind: kind, destination: destination)
    }

    private static func htmlChecklist(
        _ items: [SummaryBlock.ChecklistItem],
        destination: Destination
    ) -> String? {
        let renderedItems = items.compactMap { item -> RenderedHTMLListItem? in
            normalizedInlineMarkdown(item.text.text).nilIfBlank.map {
                RenderedHTMLListItem(html: renderInlineHTML($0), indent: item.indent, value: nil)
            }
        }
        guard !renderedItems.isEmpty else { return nil }
        return renderHTMLListItems(renderedItems, kind: .bulleted, destination: destination)
    }

    private static func renderHTMLListItems(
        _ items: [RenderedHTMLListItem],
        kind: SummaryHTMLListKind,
        destination: Destination
    ) -> String {
        switch destination {
        case .googleDocs:
            nestedHTMLList(items, kind: kind)
        case .slack:
            items.map { item in
                let indentation = String(repeating: "&nbsp;", count: item.indent * 4)
                let marker = item.value.map { "\($0)." } ?? "•"
                return "\(indentation)\(marker) \(item.html)"
            }
            .joined(separator: "<br>\n")
        }
    }

    private static func nestedHTMLList(_ items: [RenderedHTMLListItem], kind: SummaryHTMLListKind) -> String {
        let element = kind.element
        var html = "<\(element)>\n"
        var currentIndent = items[0].indent
        html += htmlListItemOpening(items[0]) + items[0].html

        for item in items.dropFirst() {
            if item.indent == currentIndent {
                html += "</li>\n" + htmlListItemOpening(item) + item.html
            } else if item.indent > currentIndent {
                for level in currentIndent ..< item.indent {
                    let opening = level == item.indent - 1 ? htmlListItemOpening(item) : "<li>"
                    html += "\n<\(element)>\n\(opening)"
                }
                html += item.html
            } else {
                html += "</li>"
                for _ in item.indent ..< currentIndent {
                    html += "\n</\(element)>\n</li>"
                }
                html += "\n" + htmlListItemOpening(item) + item.html
            }
            currentIndent = item.indent
        }

        html += "</li>"
        for _ in 0 ..< currentIndent {
            html += "\n</\(element)>\n</li>"
        }
        return html + "\n</\(element)>"
    }

    private static func htmlListItemOpening(_ item: RenderedHTMLListItem) -> String {
        item.value.map { "<li value=\"\($0)\">" } ?? "<li>"
    }

    private static func wrapHTMLList(_ renderedItems: [String], element: String) -> String {
        "<\(element)>\n\(renderedItems.joined(separator: "\n"))\n</\(element)>"
    }

    private static func renderHTMLTable(
        headers: [SummaryText],
        rows: [[SummaryText]],
        destination: Destination
    ) -> String? {
        guard !headers.isEmpty else { return nil }

        switch destination {
        case .googleDocs:
            let headerCells = headers.map { "<th>\(renderInlineHTML(normalizedInlineMarkdown($0.text)))</th>" }
            let rowHTML = rows.map { row in
                let cells = row.map { "<td>\(renderInlineHTML(normalizedInlineMarkdown($0.text)))</td>" }
                return "<tr>\(cells.joined())</tr>"
            }
            return """
            <table>
            <thead><tr>\(headerCells.joined())</tr></thead>
            <tbody>
            \(rowHTML.joined(separator: "\n"))
            </tbody>
            </table>
            """
        case .slack:
            let header = headers.map { renderInlineHTML(normalizedInlineMarkdown($0.text)) }.joined(separator: " | ")
            let rowLines = rows.map { row in
                row.map { renderInlineHTML(normalizedInlineMarkdown($0.text)) }.joined(separator: " | ")
            }
            return ([header] + rowLines).joined(separator: "<br>\n")
        }
    }

    private static func renderHTMLActionItems(
        _ actionItems: [SummaryActionItem],
        heading: String,
        destination: Destination
    ) -> RenderedHTMLBlock? {
        let items = actionItems.compactMap(normalizedActionItem)
        guard !items.isEmpty else { return nil }

        let renderedItems = items.map { item in
            let assignee = item.assignee.map { " (\(renderInlineHTML($0)))" } ?? ""
            return "\(renderInlineHTML(item.title))\(assignee)"
        }
        let heading = renderHTMLHeading(normalizedInlineMarkdown(heading), level: 2, destination: destination)

        switch destination {
        case .googleDocs:
            let list = wrapHTMLList(renderedItems.map { "<li>\($0)</li>" }, element: "ul")
            return RenderedHTMLBlock(html: "<section>\n\(heading)\n\(list)\n</section>", endsInList: true)
        case .slack:
            let list = wrapHTMLList(renderedItems.map { "<li>\($0)</li>" }, element: "ul")
            let html = joinHTMLBlocks(
                [
                    RenderedHTMLBlock(html: heading, endsInList: false),
                    RenderedHTMLBlock(html: list, endsInList: true),
                ],
                destination: destination
            )
            return RenderedHTMLBlock(html: html, endsInList: true)
        }
    }

    private static func renderHTMLHeading(_ markdown: String, level: Int, destination: Destination) -> String {
        let html = renderInlineHTML(markdown)
        switch destination {
        case .googleDocs:
            let element = "h\(level)"
            return "<\(element)>\(html)</\(element)>"
        case .slack:
            switch level {
            case 1:
                return "<strong><em>\(html)</em></strong>"
            case 2:
                return "<strong><u>\(html)</u></strong>"
            case 3:
                return "<strong>\(html)</strong>"
            default:
                return html
            }
        }
    }

    private static func joinHTMLBlocks(_ blocks: [RenderedHTMLBlock], destination: Destination) -> String {
        switch destination {
        case .googleDocs:
            return blocks.map(\.html).joined(separator: "\n")
        case .slack:
            guard let first = blocks.first else { return "" }
            var html = first.html
            var previousBlock = first
            for block in blocks.dropFirst() {
                let separator = previousBlock.endsInList ? "<br>\n" : "<br><br>\n"
                html.append(separator)
                html.append(block.html)
                previousBlock = block
            }
            return html
        }
    }

    private static func normalizedActionItem(_ item: SummaryActionItem) -> (title: String, assignee: String?)? {
        guard let title = normalizedInlineMarkdown(item.title).nilIfBlank else { return nil }
        return (title, normalizedInlineMarkdown(item.assignee).nilIfBlank)
    }

    private static func renderInlineHTML(_ markdown: String) -> String {
        guard let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return escapedInlineHTML(markdown)
        }

        return attributed.runs.map { run in
            var html = escapedInlineHTML(String(attributed[run.range].characters))

            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    html = "<code>\(html)</code>"
                }
                if intent.contains(.stronglyEmphasized) {
                    html = "<strong>\(html)</strong>"
                }
                if intent.contains(.emphasized) {
                    html = "<em>\(html)</em>"
                }
                if intent.contains(.strikethrough) {
                    html = "<del>\(html)</del>"
                }
            }

            if let link = run.link, isSafeHTMLLink(link) {
                html = "<a href=\"\(escapeHTMLAttribute(link.absoluteString))\">\(html)</a>"
            }
            return html
        }
        .joined()
    }

    private static func normalizedInlineMarkdown(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing(#/!\[([^\]]*)\]\([^)]+\)/#) { match in
                String(match.1)
            }
    }

    private static func nonBlankPreservingWhitespace(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private static func joinedChunks(_ chunks: [String]) -> String {
        chunks
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clampedHeadingLevel(_ level: Int) -> Int {
        min(max(level, 3), 6)
    }

    private static func isSafeHTMLLink(_ link: URL) -> Bool {
        guard let scheme = link.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }

    private static func escapedInlineHTML(_ text: String) -> String {
        escapeHTML(text).replacing("\n", with: "<br>")
    }

    private static func escapeHTMLAttribute(_ text: String) -> String {
        escapeHTML(text).replacing("\"", with: "&quot;")
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacing("&", with: "&amp;")
            .replacing("<", with: "&lt;")
            .replacing(">", with: "&gt;")
    }
}
