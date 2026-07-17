import Foundation

enum StoredSummaryDocumentMarkdownRenderer {
    static func decode(json: String) throws -> StoredSummaryDocument {
        try JSONDecoder().decode(StoredSummaryDocument.self, from: Data(json.utf8))
    }

    static func render(json: String) throws -> String {
        try render(decode(json: json))
    }

    static func render(_ document: StoredSummaryDocument) -> String {
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

    static func jsonValue(_ document: StoredSummaryDocument) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(document))
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
                guard let reference = normalized(text.transcriptRef ?? "") else { return block }
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

    private static func renderList(_ items: [StoredSummaryText], prefix: (Int) -> String) -> String? {
        items.enumerated().compactMap { index, item in
            renderText(item).map { "\(prefix(index)) \($0)" }
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
            appendTranscriptReference(text.text, reference: text.transcriptRef)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacing("|", with: "\\|")
                .replacing("\n", with: "<br>")
        }
        return "| " + values.joined(separator: " | ") + " |"
    }

    private static func renderText(_ text: StoredSummaryText) -> String? {
        normalized(text.text).map { appendTranscriptReference($0, reference: text.transcriptRef) }
    }

    private static func appendTranscriptReference(_ text: String, reference: String?) -> String {
        guard let reference = normalized(reference ?? "") else { return text }
        return "\(text) [Transcript \(reference)]"
    }

    private static func renderScreenshot(id: UUID, caption: StoredSummaryText) -> String {
        let marker = normalized(caption.transcriptRef ?? "").map {
            "[Screenshot \(id.uuidString) at \($0)]"
        } ?? "[Screenshot \(id.uuidString)]"
        guard let caption = normalized(caption.text) else { return marker }
        return "\(marker) \(caption)"
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

struct StoredSummaryDocument: Codable {
    let schemaVersion: Int
    let title: String
    let description: String
    let sections: [StoredSummarySection]
    let tags: [String]
    let actionItems: [StoredSummaryActionItem]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case title
        case description
        case sections
        case tags
        case actionItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        sections = try container.decode([StoredSummarySection].self, forKey: .sections)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        actionItems = try container.decodeIfPresent([StoredSummaryActionItem].self, forKey: .actionItems) ?? []
    }
}

struct StoredSummarySection: Codable {
    let id: UUID
    let heading: String
    let blocks: [StoredSummaryBlock]
}

struct StoredSummaryText: Codable {
    let text: String
    let transcriptRef: String?

    private enum CodingKeys: String, CodingKey {
        case text
        case transcriptRef = "transcript_ref"
    }
}

struct StoredSummaryActionItem: Codable {
    let title: String
    let assignee: String
}

struct StoredSummaryChecklistItem: Codable {
    let text: StoredSummaryText
    let checked: Bool

    private enum CodingKeys: String, CodingKey {
        case text
        case transcriptRef = "transcript_ref"
        case checked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try StoredSummaryText(
            text: container.decode(String.self, forKey: .text),
            transcriptRef: container.decodeIfPresent(String.self, forKey: .transcriptRef)
        )
        checked = (try? container.decode(Bool.self, forKey: .checked)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text.text, forKey: .text)
        try container.encodeIfPresent(text.transcriptRef, forKey: .transcriptRef)
        try container.encode(checked, forKey: .checked)
    }
}

struct StoredSummaryBlock: Codable {
    enum Content {
        case paragraph(StoredSummaryText)
        case bulletedList([StoredSummaryText])
        case numberedList([StoredSummaryText])
        case checklist([StoredSummaryChecklistItem])
        case quote(StoredSummaryText)
        case code(language: String, text: StoredSummaryText)
        case image(screenshotID: UUID, caption: StoredSummaryText)
        case heading(level: Int, text: StoredSummaryText)
        case table(headers: [StoredSummaryText], rows: [[StoredSummaryText]])
    }

    let id: UUID
    let content: Content

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case content
        case items
        case language
        case screenshotID = "screenshot_id"
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
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? Self.legacyID(codingPath: decoder.codingPath)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? BlockType.paragraph.rawValue
        let emptyText = StoredSummaryText(text: "", transcriptRef: nil)

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
            let caption = (try? container.decode(StoredSummaryText.self, forKey: .content)) ?? emptyText
            if let screenshotID = try? container.decode(UUID.self, forKey: .screenshotID) {
                content = .image(screenshotID: screenshotID, caption: caption)
            } else {
                content = .paragraph(caption)
            }
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

    private static func legacyID(codingPath: [CodingKey]) -> UUID {
        let seed = codingPath.map(\.stringValue).joined(separator: "/")
        var high: UInt64 = 14_695_981_039_346_656_037
        var low: UInt64 = 1_099_511_628_211
        for byte in seed.utf8 {
            high = (high ^ UInt64(byte)) &* 1_099_511_628_211
            low = (low ^ UInt64(byte)) &* 14_029_467_366_897_019_727
        }
        var bytes = (0 ..< 16).map { index -> UInt8 in
            let value = index < 8 ? high : low
            return UInt8(truncatingIfNeeded: value >> UInt64((7 - index % 8) * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        switch content {
        case let .paragraph(text):
            try container.encode(BlockType.paragraph.rawValue, forKey: .type)
            try container.encode(text, forKey: .content)
        case let .bulletedList(items):
            try container.encode(BlockType.bulletedList.rawValue, forKey: .type)
            try container.encode(items, forKey: .items)
        case let .numberedList(items):
            try container.encode(BlockType.numberedList.rawValue, forKey: .type)
            try container.encode(items, forKey: .items)
        case let .checklist(items):
            try container.encode(BlockType.checklist.rawValue, forKey: .type)
            try container.encode(items, forKey: .items)
        case let .quote(text):
            try container.encode(BlockType.quote.rawValue, forKey: .type)
            try container.encode(text, forKey: .content)
        case let .code(language, text):
            try container.encode(BlockType.code.rawValue, forKey: .type)
            try container.encode(language, forKey: .language)
            try container.encode(text, forKey: .content)
        case let .image(screenshotID, caption):
            try container.encode(BlockType.image.rawValue, forKey: .type)
            try container.encode(screenshotID, forKey: .screenshotID)
            try container.encode(caption, forKey: .content)
        case let .heading(level, text):
            try container.encode(BlockType.heading.rawValue, forKey: .type)
            try container.encode(level, forKey: .level)
            try container.encode(text, forKey: .content)
        case let .table(headers, rows):
            try container.encode(BlockType.table.rawValue, forKey: .type)
            try container.encode(headers, forKey: .headers)
            try container.encode(rows, forKey: .rows)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
