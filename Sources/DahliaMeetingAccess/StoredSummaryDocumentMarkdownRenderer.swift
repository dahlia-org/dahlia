import DahliaRuntimeSupport
import Foundation

/// 保存済みサマリーを MCP が扱う 2 つの形へ変換する。
///
/// - `render`: エージェントがそのまま読める素の Markdown。
/// - `toolJSONValue` / `decode(toolJSON:)`: `get_meeting` の出力と `update_meeting_summary` の入力で共有する
///   snake_case の構造化表現。この 2 つは必ず逆変換の対でなければならない。
enum StoredSummaryDocumentMarkdownRenderer {
    /// DB 保存形と MCP 公開形で綴りが異なるキー。ほかのキーは両形で同一。
    private static let toolKeyByDatabaseKey = ["schemaVersion": "schema_version", "actionItems": "action_items"]
    private static let databaseKeyByToolKey = ["schema_version": "schemaVersion", "action_items": "actionItems"]

    static func decode(json: String) throws -> SummaryDocument {
        try SummaryDocument.decode(databaseJSON: json)
    }

    static func render(json: String) throws -> String {
        try render(decode(json: json))
    }

    static func render(_ document: SummaryDocument) -> String {
        var chunks: [String] = []

        if let title = normalized(document.title) {
            chunks.append("# \(title)")
        }
        chunks.append(contentsOf: document.sections.compactMap(renderSection))
        if let actionItems = renderActionItems(document.actionItems) {
            chunks.append(actionItems)
        }
        return joined(chunks)
    }

    /// `get_meeting` が返し、`update_meeting_summary` が受け取る snake_case 表現。
    static func toolJSONValue(_ document: SummaryDocument) throws -> JSONValue {
        let data = try JSONEncoder().encode(document)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return rewritingKeys(value, using: toolKeyByDatabaseKey)
    }

    /// `toolJSONValue` の逆変換。
    static func decode(toolJSON: JSONValue) throws -> SummaryDocument {
        let databaseShaped = rewritingKeys(toolJSON, using: databaseKeyByToolKey)
        return try JSONDecoder().decode(SummaryDocument.self, from: JSONEncoder().encode(databaseShaped))
    }

    private static func rewritingKeys(_ value: JSONValue, using mapping: [String: String]) -> JSONValue {
        switch value {
        case let .object(object):
            .object(Dictionary(uniqueKeysWithValues: object.map { key, element in
                (mapping[key] ?? key, rewritingKeys(element, using: mapping))
            }))
        case let .array(elements):
            .array(elements.map { rewritingKeys($0, using: mapping) })
        default:
            value
        }
    }

    private static func renderSection(_ section: SummarySection) -> String? {
        var chunks: [String] = []
        if let heading = normalized(section.heading) {
            chunks.append("## \(heading)")
        }
        chunks.append(contentsOf: section.blocks.compactMap(renderBlock))
        return joined(chunks).nonEmpty
    }

    private static func renderBlock(_ block: SummaryBlock) -> String? {
        switch block.content {
        case let .paragraph(text):
            renderText(text)
        case let .bulletedList(items):
            renderList(items, prefix: { _ in "-" })
        case let .numberedList(items):
            renderList(items, prefix: { "\($0 + 1)." })
        case let .checklist(items):
            items.compactMap { item in
                renderText(item.text).map { "- [\(item.checked ? "x" : " ")] \($0)" }
            }
            .joined(separator: "\n")
            .nonEmpty
        case let .quote(text):
            renderText(text)?
                .components(separatedBy: .newlines)
                .compactMap { normalized($0) }
                .map { "> \($0)" }
                .joined(separator: "\n")
                .nonEmpty
        case let .code(language, text):
            text.text.nonEmpty.map { code in
                let fence = codeFence(for: code)
                let language = language.replacing(/[^A-Za-z0-9_+.-]/, with: "")
                let block = "\(fence)\(language)\n\(code)\n\(fence)"
                guard let reference = normalized(text.transcriptRef?.time ?? "") else { return block }
                return "\(block)\n\n[Transcript \(reference)]"
            }
        case let .image(screenshotID, caption):
            renderScreenshot(id: screenshotID, caption: caption)
        case let .heading(level, text):
            renderText(text).map {
                "\(String(repeating: "#", count: min(max(level, 3), 6))) \($0)"
            }
        case let .table(headers, rows):
            renderTable(headers: headers, rows: rows)
        }
    }

    private static func renderList(_ items: [SummaryText], prefix: (Int) -> String) -> String? {
        items.enumerated().compactMap { index, item in
            renderText(item).map { "\(prefix(index)) \($0)" }
        }
        .joined(separator: "\n")
        .nonEmpty
    }

    private static func renderTable(headers: [SummaryText], rows: [[SummaryText]]) -> String? {
        guard !headers.isEmpty else { return nil }
        let header = tableRow(headers)
        let separator = "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |"
        return ([header, separator] + rows.map(tableRow)).joined(separator: "\n")
    }

    private static func tableRow(_ cells: [SummaryText]) -> String {
        let values = cells.map { text in
            appendTranscriptReference(text.text, reference: text.transcriptRef?.time)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacing("|", with: "\\|")
                .replacing("\n", with: "<br>")
        }
        return "| " + values.joined(separator: " | ") + " |"
    }

    private static func renderText(_ text: SummaryText) -> String? {
        normalized(text.text).map { appendTranscriptReference($0, reference: text.transcriptRef?.time) }
    }

    private static func appendTranscriptReference(_ text: String, reference: String?) -> String {
        guard let reference = normalized(reference ?? "") else { return text }
        return "\(text) [Transcript \(reference)]"
    }

    private static func renderScreenshot(id: UUID, caption: SummaryText) -> String {
        let marker = normalized(caption.transcriptRef?.time ?? "").map {
            "[Screenshot \(id.uuidString) at \($0)]"
        } ?? "[Screenshot \(id.uuidString)]"
        guard let caption = normalized(caption.text) else { return marker }
        return "\(marker) \(caption)"
    }

    private static func renderActionItems(_ items: [SummaryActionItem]) -> String? {
        let lines = items.compactMap { item -> String? in
            guard let title = normalized(item.title) else { return nil }
            let assignee = normalized(item.assignee).map { " (\($0))" } ?? ""
            return "- [ ] \(title)\(assignee)"
        }
        guard !lines.isEmpty else { return nil }
        return (["## Action Items"] + lines).joined(separator: "\n")
    }

    private static func codeFence(for code: String) -> String {
        var longestRun = 0
        var currentRun = 0
        for character in code {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return String(repeating: "`", count: max(3, longestRun + 1))
    }

    private static func normalized(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing(#/!\[([^\]]*)\]\([^)]+\)/#) { String($0.1) }
            .nonEmpty
    }

    private static func joined(_ chunks: [String]) -> String {
        chunks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
