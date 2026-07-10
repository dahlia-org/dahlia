import Foundation

struct SummaryShareContent {
    let html: String
    let markdown: String
}

enum SummaryShareRenderer {
    enum Destination {
        case googleDocs
        case slack
    }

    private enum HTMLListKind {
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

    static func render(
        document: SummaryDocument,
        actionItemsHeading: String,
        for destination: Destination
    ) -> SummaryShareContent {
        SummaryShareContent(
            html: renderHTML(document: document, actionItemsHeading: actionItemsHeading, destination: destination),
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
        switch block.content {
        case let .paragraph(text):
            normalizedInlineMarkdown(text.text).nilIfBlank
        case let .bulletedList(items):
            renderMarkdownBulletList(items.map(\.text))
        case let .numberedList(items):
            items.enumerated()
                .compactMap { index, item in
                    normalizedInlineMarkdown(item.text).nilIfBlank.map { "\(index + 1). \($0)" }
                }
                .joined(separator: "\n")
                .nilIfBlank
        case let .checklist(items):
            items.compactMap { item in
                normalizedInlineMarkdown(item.text.text).nilIfBlank.map { "- [\(item.checked ? "x" : " ")] \($0)" }
            }
            .joined(separator: "\n")
            .nilIfBlank
        case let .quote(text):
            normalizedInlineMarkdown(text.text)
                .components(separatedBy: .newlines)
                .compactMap(\.nilIfBlank)
                .map { "> \($0)" }
                .joined(separator: "\n")
                .nilIfBlank
        case let .code(language, content):
            content.text.nilIfBlank.map { "```\(language)\n\($0)\n```" }
        case let .image(_, caption):
            normalizedInlineMarkdown(caption.text).nilIfBlank
        case let .heading(level, content):
            normalizedInlineMarkdown(content.text).nilIfBlank.map {
                "\(String(repeating: "#", count: clampedHeadingLevel(level))) \($0)"
            }
        case let .table(headers, rows):
            renderMarkdownTable(headers: headers, rows: rows)
        }
    }

    private static func renderMarkdownBulletList(_ items: [String]) -> String? {
        items.compactMap { item in
            normalizedInlineMarkdown(item).nilIfBlank.map { "- \($0)" }
        }
        .joined(separator: "\n")
        .nilIfBlank
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
        destination: Destination
    ) -> String {
        var chunks: [String] = []

        if let title = normalizedInlineMarkdown(document.title).nilIfBlank {
            chunks.append(renderHTMLHeading(title, level: 1, destination: destination))
        }

        chunks.append(contentsOf: document.sections.compactMap { section in
            renderHTMLSection(section, destination: destination)
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

    private static func renderHTMLSection(_ section: SummarySection, destination: Destination) -> String? {
        var chunks: [String] = []

        if let heading = normalizedInlineMarkdown(section.heading).nilIfBlank {
            chunks.append(renderHTMLHeading(heading, level: 2, destination: destination))
        }

        chunks.append(contentsOf: section.blocks.compactMap { block in
            renderHTMLBlock(block, destination: destination)
        })
        guard !chunks.isEmpty else { return nil }

        let body = joinHTMLBlocks(chunks, destination: destination)
        switch destination {
        case .googleDocs:
            return "<section>\n\(body)\n</section>"
        case .slack:
            return body
        }
    }

    private static func renderHTMLBlock(_ block: SummaryBlock, destination: Destination) -> String? {
        switch block.content {
        case let .paragraph(text):
            htmlParagraph(text.text, destination: destination)
        case let .bulletedList(items):
            htmlList(items.map(\.text), kind: .bulleted, destination: destination)
        case let .numberedList(items):
            htmlList(items.map(\.text), kind: .numbered, destination: destination)
        case let .checklist(items):
            htmlChecklist(items, destination: destination)
        case let .quote(text):
            htmlParagraph(text.text, destination: destination).map { "<blockquote>\($0)</blockquote>" }
        case let .code(_, content):
            content.text.nilIfBlank.map { "<pre><code>\(escapeHTML($0))</code></pre>" }
        case let .image(_, caption):
            normalizedInlineMarkdown(caption.text).nilIfBlank.map {
                let html = "<em>\(renderInlineHTML($0))</em>"
                switch destination {
                case .googleDocs:
                    return "<p>\(html)</p>"
                case .slack:
                    return html
                }
            }
        case let .heading(level, content):
            normalizedInlineMarkdown(content.text).nilIfBlank.map {
                let headingLevel = destination == .googleDocs ? clampedHeadingLevel(level) : level
                return renderHTMLHeading($0, level: headingLevel, destination: destination)
            }
        case let .table(headers, rows):
            renderHTMLTable(headers: headers, rows: rows, destination: destination)
        }
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
        _ items: [String],
        kind: HTMLListKind,
        destination: Destination
    ) -> String? {
        let renderedItems = items.compactMap { item -> String? in
            normalizedInlineMarkdown(item).nilIfBlank.map(renderInlineHTML)
        }
        guard !renderedItems.isEmpty else { return nil }

        switch destination {
        case .googleDocs:
            return wrapHTMLList(renderedItems.map { "<li>\($0)</li>" }, element: kind.element)
        case .slack:
            let lines = renderedItems.enumerated().map { index, item in
                switch kind {
                case .bulleted:
                    "• \(item)"
                case .numbered:
                    "\(index + 1). \(item)"
                }
            }
            return lines.joined(separator: "<br>\n")
        }
    }

    private static func htmlChecklist(_ items: [SummaryBlock.ChecklistItem], destination: Destination) -> String? {
        let renderedItems = items.compactMap { item -> String? in
            guard let text = normalizedInlineMarkdown(item.text.text).nilIfBlank else { return nil }
            let marker = item.checked ? "☑" : "☐"
            return "\(marker) \(renderInlineHTML(text))"
        }
        guard !renderedItems.isEmpty else { return nil }

        switch destination {
        case .googleDocs:
            return wrapHTMLList(renderedItems.map { "<li>\($0)</li>" }, element: "ul")
        case .slack:
            return renderedItems.joined(separator: "<br>\n")
        }
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
    ) -> String? {
        let items = actionItems.compactMap(normalizedActionItem)
        guard !items.isEmpty else { return nil }

        let renderedItems = items.map { item in
            let assignee = item.assignee.map { " (\(renderInlineHTML($0)))" } ?? ""
            return "☐ \(renderInlineHTML(item.title))\(assignee)"
        }
        let heading = renderHTMLHeading(normalizedInlineMarkdown(heading), level: 2, destination: destination)

        switch destination {
        case .googleDocs:
            let list = wrapHTMLList(renderedItems.map { "<li>\($0)</li>" }, element: "ul")
            return "<section>\n\(heading)\n\(list)\n</section>"
        case .slack:
            let list = renderedItems.joined(separator: "<br>\n")
            return joinHTMLBlocks([heading, list], destination: destination)
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

    private static func joinHTMLBlocks(_ blocks: [String], destination: Destination) -> String {
        let separator = switch destination {
        case .googleDocs:
            "\n"
        case .slack:
            "<br><br>\n"
        }
        return blocks.joined(separator: separator)
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
