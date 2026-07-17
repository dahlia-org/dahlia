import Foundation

struct SummaryMarkdownRenderResult: Equatable {
    let fileName: String
    let markdown: String
    let body: String
}

enum ObsidianMarkdownSummaryRenderer {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func render(document: SummaryDocument, context: SummaryRenderContext) -> SummaryMarkdownRenderResult {
        let body = renderBody(document: document, context: context)
        let markdown = renderFrontmatter(document: document, context: context) + "\n\n" + body + "\n"
        let fileName = summaryFileName(
            datePrefix: dateFormatter.string(from: context.createdAt),
            title: document.title,
            meetingId: context.meetingId
        ) + ".md"

        return SummaryMarkdownRenderResult(fileName: fileName, markdown: markdown, body: body)
    }

    private static func renderFrontmatter(document: SummaryDocument, context: SummaryRenderContext) -> String {
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

    private static func renderBody(document: SummaryDocument, context: SummaryRenderContext) -> String {
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

        if let actionItems = renderActionItems(document.actionItems) {
            chunks.append(actionItems)
        }

        return chunks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderActionItems(_ actionItems: [SummaryActionItem]) -> String? {
        let lines = actionItems.compactMap { item -> String? in
            guard let title = item.title.nilIfBlank else { return nil }
            let assignee = item.assignee.nilIfBlank.map { " (\($0))" } ?? ""
            return "- [ ] \(title)\(assignee)"
        }
        guard !lines.isEmpty else { return nil }

        return (["## \(L10n.actionItems)"] + lines).joined(separator: "\n")
    }

    private static func renderBlock(_ block: SummaryBlock, context: SummaryRenderContext) -> String? {
        let meetingId = context.meetingId
        let rendered: String?
        switch block.content {
        case let .paragraph(text):
            rendered = renderSummaryText(text, meetingId: meetingId, placement: .inline).nilIfBlank
        case let .bulletedList(items):
            rendered = items
                .map { "- \(renderSummaryText($0, meetingId: meetingId, placement: .inline))" }
                .joined(separator: "\n")
                .nilIfBlank
        case let .numberedList(items):
            rendered = items.enumerated()
                .map { "\($0.offset + 1). \(renderSummaryText($0.element, meetingId: meetingId, placement: .inline))" }
                .joined(separator: "\n")
                .nilIfBlank
        case let .checklist(items):
            rendered = items
                .map { "- [\($0.checked ? "x" : " ")] \(renderSummaryText($0.text, meetingId: meetingId, placement: .inline))" }
                .joined(separator: "\n")
                .nilIfBlank
        case let .quote(text):
            let quoted = renderSummaryText(text, meetingId: meetingId, placement: .inline)
                .components(separatedBy: .newlines)
                .map { "> \($0)" }
                .joined(separator: "\n")
            rendered = quoted.nilIfBlank
        case let .code(language, content):
            rendered = appendReference(
                to: "```\(language)\n\(content.text)\n```",
                ref: content.transcriptRef,
                meetingId: meetingId,
                placement: .separateParagraph
            )
        case let .image(screenshotId, caption):
            let image = "![[\(screenshotFilename(for: screenshotId, context: context))]]"
            if caption.text.nilIfBlank != nil {
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
            .nilIfBlank ?? ""
    }

    private static func screenshotFilename(for screenshotId: UUID, context: SummaryRenderContext) -> String {
        guard let screenshot = context.screenshots.first(where: { $0.id == screenshotId }) else {
            return screenshotId.uuidString
        }
        return ScreenshotExportService.filename(for: screenshot)
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
