import Foundation

public struct SummaryMarkdownRenderResult: Equatable, Sendable {
    public let fileName: String
    public let markdown: String
    public let body: String

    public init(fileName: String, markdown: String, body: String) {
        self.fileName = fileName
        self.markdown = markdown
        self.body = body
    }
}

/// Obsidian Markdown を描画するために必要な最小の文脈。
/// アプリと MCP ヘルパーはスクリーンショットの表現が異なるため、ファイル名だけを受け取る。
public struct SummaryMarkdownRenderContext: Sendable {
    public let meetingId: UUID
    public let createdAt: Date
    public let screenshotFilenames: [UUID: String]

    public init(meetingId: UUID, createdAt: Date, screenshotFilenames: [UUID: String] = [:]) {
        self.meetingId = meetingId
        self.createdAt = createdAt
        self.screenshotFilenames = screenshotFilenames
    }
}

/// Vault に書き出すスクリーンショットのファイル名規則。アプリと MCP ヘルパーで共有する。
public enum SummaryScreenshotFilename {
    /// mime type だけで拡張子が決まる場合のファイル名。決まらない場合は nil。
    public static func filename(id: UUID, mimeType: String) -> String? {
        ImageEncoder.fileExtension(for: mimeType).map { "\(id.uuidString).\($0)" }
    }

    /// 画像データの内容も見て拡張子を決めるファイル名。
    public static func filename(id: UUID, mimeType: String, imageData: Data) -> String {
        "\(id.uuidString).\(ImageEncoder.fileExtension(mimeType: mimeType, data: imageData))"
    }
}

public enum ObsidianMarkdownSummaryRenderer {
    /// `SummaryDocument` にローカライズ済みの見出しが存在しないため、呼び出し側が渡す。
    /// ja / en とも同じ訳文であり、既定値はアプリの `L10n.actionItems` と一致していなければならない。
    public static let defaultActionItemsHeading = "Action Items"

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func render(
        document: SummaryDocument,
        context: SummaryMarkdownRenderContext,
        actionItemsHeading: String = defaultActionItemsHeading
    ) -> SummaryMarkdownRenderResult {
        let body = renderBody(document: document, context: context, actionItemsHeading: actionItemsHeading)
        let markdown = renderFrontmatter(document: document, context: context) + "\n\n" + body + "\n"
        let fileName = summaryFileName(
            datePrefix: dateFormatter.string(from: context.createdAt),
            title: document.title,
            meetingId: context.meetingId
        ) + ".md"

        return SummaryMarkdownRenderResult(fileName: fileName, markdown: markdown, body: body)
    }

    private static func renderFrontmatter(document: SummaryDocument, context: SummaryMarkdownRenderContext) -> String {
        let dateString = dateFormatter.string(from: context.createdAt)
        var fields = """
        meeting_id: "\(context.meetingId.uuidString)"
        date: \(dateString)
        """

        if !document.title.isEmpty {
            fields += "\ntitle: \"\(escapeYAMLString(document.title))\""
        }
        if !document.tags.isEmpty {
            let tagsYAML = document.tags.map { "  - \($0)" }.joined(separator: "\n")
            fields += "\ntags:\n\(tagsYAML)"
        }

        return "---\n\(fields)\n---"
    }

    private static func renderBody(
        document: SummaryDocument,
        context: SummaryMarkdownRenderContext,
        actionItemsHeading: String
    ) -> String {
        var chunks: [String] = []

        for section in document.sections {
            var sectionChunks: [String] = []
            if !section.heading.isEmpty {
                sectionChunks.append("## \(section.heading)")
            }
            sectionChunks.append(contentsOf: section.blocks.compactMap { renderBlock($0, context: context) })

            let sectionText = sectionChunks
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            if !sectionText.isEmpty {
                chunks.append(sectionText)
            }
        }

        if let actionItems = renderActionItems(document.actionItems, heading: actionItemsHeading) {
            chunks.append(actionItems)
        }

        return chunks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderActionItems(_ actionItems: [SummaryActionItem], heading: String) -> String? {
        let lines = actionItems.compactMap { item -> String? in
            guard let title = item.title.summaryNilIfBlank else { return nil }
            let assignee = item.assignee.summaryNilIfBlank.map { " (\($0))" } ?? ""
            return "- [ ] \(title)\(assignee)"
        }
        guard !lines.isEmpty else { return nil }

        return (["## \(heading)"] + lines).joined(separator: "\n")
    }

    private static func renderBlock(_ block: SummaryBlock, context: SummaryMarkdownRenderContext) -> String? {
        let meetingId = context.meetingId
        let rendered: String?
        switch block.content {
        case let .paragraph(text):
            rendered = renderSummaryText(text, meetingId: meetingId, placement: .inline).summaryNilIfBlank
        case let .bulletedList(items):
            rendered = nonBlankPreservingWhitespace(items
                .map { item in
                    let indentation = String(repeating: " ", count: item.indent * 4)
                    return "\(indentation)- \(renderSummaryText(item.text, meetingId: meetingId, placement: .inline))"
                }
                .joined(separator: "\n"))
        case let .numberedList(items):
            let numbers = SummaryListNumbering.numbers(for: items.map(\.indent))
            rendered = nonBlankPreservingWhitespace(zip(items, numbers)
                .map { item, number in
                    let indentation = String(repeating: " ", count: item.indent * 4)
                    return "\(indentation)\(number). \(renderSummaryText(item.text, meetingId: meetingId, placement: .inline))"
                }
                .joined(separator: "\n"))
        case let .checklist(items):
            rendered = nonBlankPreservingWhitespace(items
                .map { item in
                    let indentation = String(repeating: " ", count: item.indent * 4)
                    return "\(indentation)- [\(item.checked ? "x" : " ")] "
                        + renderSummaryText(item.text, meetingId: meetingId, placement: .inline)
                }
                .joined(separator: "\n"))
        case let .quote(text):
            let quoted = renderSummaryText(text, meetingId: meetingId, placement: .inline)
                .components(separatedBy: .newlines)
                .map { "> \($0)" }
                .joined(separator: "\n")
            rendered = quoted.summaryNilIfBlank
        case let .code(language, content):
            rendered = appendReference(
                to: "```\(language)\n\(content.text)\n```",
                ref: content.transcriptRef,
                meetingId: meetingId,
                placement: .separateParagraph
            )
        case let .image(screenshotId, caption):
            let image = "![[\(screenshotFilename(for: screenshotId, context: context))]]"
            if caption.text.summaryNilIfBlank != nil {
                rendered = "\(image)\n\n\(renderSummaryText(caption, meetingId: meetingId, placement: .inline))"
            } else {
                rendered = appendReference(to: image, ref: caption.transcriptRef, meetingId: meetingId, placement: .separateParagraph)
            }
        case let .heading(level, content):
            let clampedLevel = max(3, min(level, 6))
            let headingPrefix = String(repeating: "#", count: clampedLevel)
            rendered = "\(headingPrefix) \(renderSummaryText(content, meetingId: meetingId, placement: .inline))"
        case let .table(headers, rows):
            rendered = renderTable(headers: headers, rows: rows, meetingId: meetingId)
        }

        return rendered
    }

    private static func nonBlankPreservingWhitespace(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private enum ReferencePlacement {
        case inline
        case separateParagraph
    }

    private static func renderTable(headers: [SummaryText], rows: [[SummaryText]], meetingId: UUID) -> String? {
        guard !headers.isEmpty else { return nil }

        let header = renderTableRow(headers, meetingId: meetingId)
        let separator = "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |"
        let rowLines = rows.map { renderTableRow($0, meetingId: meetingId) }
        return ([header, separator] + rowLines).joined(separator: "\n")
    }

    private static func renderTableRow(_ cells: [SummaryText], meetingId: UUID) -> String {
        let renderedCells = cells.map { renderSummaryText($0, meetingId: meetingId, placement: .inline) }
        return "| " + renderedCells.joined(separator: " | ") + " |"
    }

    private static func renderSummaryText(_ text: SummaryText, meetingId: UUID, placement: ReferencePlacement) -> String {
        appendReference(
            to: text.text,
            ref: text.transcriptRef,
            meetingId: meetingId,
            placement: placement
        )
    }

    private static func appendReference(
        to text: String,
        ref: TranscriptReference?,
        meetingId: UUID,
        placement: ReferencePlacement
    ) -> String {
        guard let ref else { return text }
        let referenceText = "[[" + meetingId.uuidString + "#" + ref.time + "|" + obsidianAlias(ref.time) + "]]"
        switch placement {
        case .inline:
            return "\(text) (\(referenceText))"
        case .separateParagraph:
            return "\(text)\n\n(\(referenceText))"
        }
    }

    private static func obsidianAlias(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "]", with: "")
            .summaryNilIfBlank ?? ""
    }

    private static func screenshotFilename(for screenshotId: UUID, context: SummaryMarkdownRenderContext) -> String {
        context.screenshotFilenames[screenshotId] ?? screenshotId.uuidString
    }

    private static func escapeYAMLString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func summaryFileName(datePrefix: String, title: String, meetingId: UUID) -> String {
        guard !title.isEmpty else {
            return "\(datePrefix)-summary_\(meetingId.uuidString)"
        }
        let sanitized = title
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "", options: .regularExpression)
        return sanitized.isEmpty
            ? "\(datePrefix)-summary_\(meetingId.uuidString)"
            : "\(datePrefix)-\(sanitized)"
    }
}
