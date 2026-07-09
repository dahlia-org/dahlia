import Foundation

struct SummaryMarkdownRenderResult: Equatable {
    let fileName: String
    let markdown: String
    let body: String
}

enum ObsidianMarkdownSummaryRenderer {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
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
                sectionChunks.append("## \(renderInlineMarkdown(section.heading, meetingId: context.meetingId))")
            }
            sectionChunks.append(contentsOf: section.blocks.compactMap { renderBlock($0, context: context) })

            let sectionText = sectionChunks
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            if !sectionText.isEmpty {
                chunks.append(sectionText)
            }
        }

        return chunks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderBlock(_ block: SummaryBlock, context: SummaryRenderContext) -> String? {
        switch block {
        case let .paragraph(text):
            return renderInlineMarkdown(text, meetingId: context.meetingId).nilIfBlank
        case let .bulletedList(items):
            return items
                .map { "- \(renderInlineMarkdown($0, meetingId: context.meetingId))" }
                .joined(separator: "\n")
                .nilIfBlank
        case let .numberedList(items):
            return items.enumerated()
                .map { "\($0.offset + 1). \(renderInlineMarkdown($0.element, meetingId: context.meetingId))" }
                .joined(separator: "\n")
                .nilIfBlank
        case let .checklist(items):
            return items
                .map { "- [\($0.checked ? "x" : " ")] \(renderInlineMarkdown($0.text, meetingId: context.meetingId))" }
                .joined(separator: "\n")
                .nilIfBlank
        case let .quote(text):
            let quoted = renderInlineMarkdown(text, meetingId: context.meetingId)
                .components(separatedBy: .newlines)
                .map { "> \($0)" }
                .joined(separator: "\n")
            return quoted.nilIfBlank
        case let .code(language, code):
            return "```\(language)\n\(code)\n```"
        case let .image(screenshotId, _):
            return "![[\(screenshotFilename(for: screenshotId, context: context))]]"
        case let .heading(level, text):
            let clampedLevel = max(3, min(level, 6))
            return "\(String(repeating: "#", count: clampedLevel)) \(renderInlineMarkdown(text, meetingId: context.meetingId))"
        case let .table(headers, rows):
            guard !headers.isEmpty else { return nil }
            let header = "| " + headers.map { renderInlineMarkdown($0, meetingId: context.meetingId) }.joined(separator: " | ") + " |"
            let separator = "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |"
            let rowLines = rows.map { row in
                let cells = row.map { renderInlineMarkdown($0, meetingId: context.meetingId) }
                return "| " + cells.joined(separator: " | ") + " |"
            }
            return ([header, separator] + rowLines).joined(separator: "\n")
        }
    }

    private static func renderInlineMarkdown(_ text: String, meetingId: UUID) -> String {
        let pattern = #"\[([^\]]+)\]\(transcript://([0-9]{2}:[0-9]{2}:[0-9]{2})\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        var rendered = text
        let matches = regex.matches(in: rendered, range: NSRange(rendered.startIndex..., in: rendered))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: rendered),
                  let labelRange = Range(match.range(at: 1), in: rendered),
                  let timeRange = Range(match.range(at: 2), in: rendered) else { continue }
            let label = String(rendered[labelRange])
            let time = String(rendered[timeRange])
            rendered.replaceSubrange(fullRange, with: "[[\(meetingId.uuidString)#\(time)|\(label)]]")
        }
        return rendered
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
