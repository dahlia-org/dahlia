import Foundation

enum StoredSummaryDocumentMarkdownRenderer {
    static func render(json: String) throws -> String {
        let document = try JSONDecoder().decode(StoredSummaryDocument.self, from: Data(json.utf8))
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

    private static func renderSection(_ section: StoredSummarySection) -> String? {
        var chunks: [String] = []
        if let heading = normalized(section.heading) {
            chunks.append("## \(heading)")
        }
        chunks.append(contentsOf: section.blocks.compactMap(renderBlock))
        return joined(chunks).nonEmpty
    }

    private static func renderBlock(_ block: StoredSummaryBlock) -> String? {
        switch block.content {
        case let .paragraph(text):
            normalized(text.text)
        case let .bulletedList(items):
            renderList(items.map(\.text), prefix: { _ in "-" })
        case let .numberedList(items):
            renderList(items.map(\.text), prefix: { "\($0 + 1)." })
        case let .checklist(items):
            items.compactMap { item in
                normalized(item.text).map { "- [\(item.checked ? "x" : " ")] \($0)" }
            }
            .joined(separator: "\n")
            .nonEmpty
        case let .quote(text):
            normalized(text.text)?
                .components(separatedBy: .newlines)
                .compactMap { normalized($0) }
                .map { "> \($0)" }
                .joined(separator: "\n")
                .nonEmpty
        case let .code(language, text):
            text.text.nonEmpty.map { code in
                let fence = codeFence(for: code)
                let language = language.replacing(/[^A-Za-z0-9_+.-]/, with: "")
                return "\(fence)\(language)\n\(code)\n\(fence)"
            }
        case let .image(caption):
            normalized(caption.text)
        case let .heading(level, text):
            normalized(text.text).map {
                "\(String(repeating: "#", count: min(max(level, 3), 6))) \($0)"
            }
        case let .table(headers, rows):
            renderTable(headers: headers, rows: rows)
        }
    }

    private static func renderList(_ items: [String], prefix: (Int) -> String) -> String? {
        items.enumerated().compactMap { index, item in
            normalized(item).map { "\(prefix(index)) \($0)" }
        }
        .joined(separator: "\n")
        .nonEmpty
    }

    private static func renderTable(headers: [StoredSummaryText], rows: [[StoredSummaryText]]) -> String? {
        guard !headers.isEmpty else { return nil }
        let header = tableRow(headers)
        let separator = "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |"
        return ([header, separator] + rows.map(tableRow)).joined(separator: "\n")
    }

    private static func tableRow(_ cells: [StoredSummaryText]) -> String {
        let values = cells.map { text in
            text.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacing("|", with: "\\|")
                .replacing("\n", with: "<br>")
        }
        return "| " + values.joined(separator: " | ") + " |"
    }

    private static func renderActionItems(_ items: [StoredSummaryActionItem]) -> String? {
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

private struct StoredSummaryDocument: Decodable {
    let title: String
    let sections: [StoredSummarySection]
    let actionItems: [StoredSummaryActionItem]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case title
        case sections
        case actionItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(Int.self, forKey: .schemaVersion)
        title = try container.decode(String.self, forKey: .title)
        sections = try container.decode([StoredSummarySection].self, forKey: .sections)
        actionItems = try container.decodeIfPresent([StoredSummaryActionItem].self, forKey: .actionItems) ?? []
    }
}

private struct StoredSummarySection: Decodable {
    let heading: String
    let blocks: [StoredSummaryBlock]
}

private struct StoredSummaryText: Decodable {
    let text: String
}

private struct StoredSummaryActionItem: Decodable {
    let title: String
    let assignee: String
}

private struct StoredSummaryChecklistItem: Decodable {
    let text: String
    let checked: Bool

    private enum CodingKeys: String, CodingKey {
        case text
        case checked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        checked = (try? container.decode(Bool.self, forKey: .checked)) ?? false
    }
}

private struct StoredSummaryBlock: Decodable {
    enum Content {
        case paragraph(StoredSummaryText)
        case bulletedList([StoredSummaryText])
        case numberedList([StoredSummaryText])
        case checklist([StoredSummaryChecklistItem])
        case quote(StoredSummaryText)
        case code(language: String, text: StoredSummaryText)
        case image(caption: StoredSummaryText)
        case heading(level: Int, text: StoredSummaryText)
        case table(headers: [StoredSummaryText], rows: [[StoredSummaryText]])
    }

    let content: Content

    private enum CodingKeys: String, CodingKey {
        case type
        case content
        case items
        case language
        case level
        case headers
        case rows
    }

    private enum BlockType: String {
        case paragraph
        case bulletedList = "bulleted_list"
        case numberedList = "numbered_list"
        case checklist
        case quote
        case code
        case image
        case heading
        case table
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? BlockType.paragraph.rawValue
        let emptyText = StoredSummaryText(text: "")

        switch BlockType(rawValue: type) {
        case .paragraph, nil:
            content = .paragraph((try? container.decode(StoredSummaryText.self, forKey: .content)) ?? emptyText)
        case .bulletedList:
            content = .bulletedList((try? container.decode([StoredSummaryText].self, forKey: .items)) ?? [])
        case .numberedList:
            content = .numberedList((try? container.decode([StoredSummaryText].self, forKey: .items)) ?? [])
        case .checklist:
            content = .checklist((try? container.decode([StoredSummaryChecklistItem].self, forKey: .items)) ?? [])
        case .quote:
            content = .quote((try? container.decode(StoredSummaryText.self, forKey: .content)) ?? emptyText)
        case .code:
            content = .code(
                language: (try? container.decode(String.self, forKey: .language)) ?? "",
                text: (try? container.decode(StoredSummaryText.self, forKey: .content)) ?? emptyText
            )
        case .image:
            content = .image(caption: (try? container.decode(StoredSummaryText.self, forKey: .content)) ?? emptyText)
        case .heading:
            content = .heading(
                level: (try? container.decode(Int.self, forKey: .level)) ?? 3,
                text: (try? container.decode(StoredSummaryText.self, forKey: .content)) ?? emptyText
            )
        case .table:
            content = .table(
                headers: (try? container.decode([StoredSummaryText].self, forKey: .headers)) ?? [],
                rows: (try? container.decode([[StoredSummaryText]].self, forKey: .rows)) ?? []
            )
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
