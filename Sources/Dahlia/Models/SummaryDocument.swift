import Foundation

struct SummaryDocument: Codable, Equatable {
    var schemaVersion: Int
    var title: String
    var sections: [SummarySection]
    var tags: [String]
    var actionItems: [SummaryActionItem]

    init(
        schemaVersion: Int = 2,
        title: String,
        sections: [SummarySection],
        tags: [String] = [],
        actionItems: [SummaryActionItem] = []
    ) {
        self.schemaVersion = schemaVersion
        self.title = title
        self.sections = sections
        self.tags = tags
        self.actionItems = actionItems
    }

    func databaseJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try String(decoding: encoder.encode(self), as: UTF8.self)
    }
}

struct SummarySection: Codable, Equatable, Identifiable {
    var id: UUID
    var heading: String
    var blocks: [SummaryBlock]
}

struct TranscriptReference: Codable, Equatable {
    var time: String

    init(time: String) {
        self.time = time
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        time = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(time)
    }
}

struct SummaryText: Codable, Equatable {
    var text: String
    var transcriptRef: TranscriptReference?

    init(_ text: String, transcriptRef: TranscriptReference? = nil) {
        self.text = text
        self.transcriptRef = transcriptRef
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case transcriptRef = "transcript_ref"
    }
}

struct SummaryBlock: Codable, Equatable, Identifiable {
    var id: UUID
    var content: SummaryBlockContent

    init(id: UUID = .v7(), content: SummaryBlockContent) {
        self.id = id
        self.content = content
    }

    typealias ChecklistItem = SummaryBlockContent.ChecklistItem

    static func paragraph(_ text: String, transcriptRef: TranscriptReference? = nil) -> SummaryBlock {
        SummaryBlock(content: .paragraph(SummaryText(text, transcriptRef: transcriptRef)))
    }

    static func paragraph(_ text: SummaryText) -> SummaryBlock {
        SummaryBlock(content: .paragraph(text))
    }

    static func bulletedList(items: [String]) -> SummaryBlock {
        SummaryBlock(content: .bulletedList(items: items.map { SummaryText($0) }))
    }

    static func bulletedList(items: [SummaryText]) -> SummaryBlock {
        SummaryBlock(content: .bulletedList(items: items))
    }

    static func numberedList(items: [String]) -> SummaryBlock {
        SummaryBlock(content: .numberedList(items: items.map { SummaryText($0) }))
    }

    static func numberedList(items: [SummaryText]) -> SummaryBlock {
        SummaryBlock(content: .numberedList(items: items))
    }

    static func checklist(items: [ChecklistItem]) -> SummaryBlock {
        SummaryBlock(content: .checklist(items: items))
    }

    static func quote(_ text: String, transcriptRef: TranscriptReference? = nil) -> SummaryBlock {
        SummaryBlock(content: .quote(SummaryText(text, transcriptRef: transcriptRef)))
    }

    static func quote(_ text: SummaryText) -> SummaryBlock {
        SummaryBlock(content: .quote(text))
    }

    static func code(language: String, code: String, transcriptRef: TranscriptReference? = nil) -> SummaryBlock {
        SummaryBlock(content: .code(language: language, content: SummaryText(code, transcriptRef: transcriptRef)))
    }

    static func code(language: String, content: SummaryText) -> SummaryBlock {
        SummaryBlock(content: .code(language: language, content: content))
    }

    static func image(screenshotId: UUID, caption: String, transcriptRef: TranscriptReference? = nil) -> SummaryBlock {
        SummaryBlock(content: .image(screenshotId: screenshotId, caption: SummaryText(caption, transcriptRef: transcriptRef)))
    }

    static func image(screenshotId: UUID, caption: SummaryText) -> SummaryBlock {
        SummaryBlock(content: .image(screenshotId: screenshotId, caption: caption))
    }

    static func heading(level: Int, text: String, transcriptRef: TranscriptReference? = nil) -> SummaryBlock {
        SummaryBlock(content: .heading(level: level, content: SummaryText(text, transcriptRef: transcriptRef)))
    }

    static func heading(level: Int, content: SummaryText) -> SummaryBlock {
        SummaryBlock(content: .heading(level: level, content: content))
    }

    static func table(headers: [String], rows: [[String]]) -> SummaryBlock {
        SummaryBlock(content: .table(headers: headers.map { SummaryText($0) }, rows: rows.map { $0.map { SummaryText($0) } }))
    }

    static func table(headers: [SummaryText], rows: [[SummaryText]]) -> SummaryBlock {
        SummaryBlock(content: .table(headers: headers, rows: rows))
    }

    static func == (lhs: SummaryBlock, rhs: SummaryBlock) -> Bool {
        lhs.content == rhs.content
    }
}

enum SummaryBlockContent: Equatable {
    case paragraph(SummaryText)
    case bulletedList(items: [SummaryText])
    case numberedList(items: [SummaryText])
    case checklist(items: [ChecklistItem])
    case quote(SummaryText)
    case code(language: String, content: SummaryText)
    case image(screenshotId: UUID, caption: SummaryText)
    case heading(level: Int, content: SummaryText)
    case table(headers: [SummaryText], rows: [[SummaryText]])

    struct ChecklistItem: Codable, Equatable {
        var text: SummaryText
        var checked: Bool

        init(text: String, transcriptRef: TranscriptReference? = nil, checked: Bool) {
            self.text = SummaryText(text, transcriptRef: transcriptRef)
            self.checked = checked
        }

        init(text: SummaryText, checked: Bool) {
            self.text = text
            self.checked = checked
        }

        private enum CodingKeys: String, CodingKey {
            case text
            case transcriptRef = "transcript_ref"
            case checked
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let value = try container.decode(String.self, forKey: .text)
            let transcriptRef = try container.decodeIfPresent(TranscriptReference.self, forKey: .transcriptRef)
            text = SummaryText(value, transcriptRef: transcriptRef)
            checked = (try? container.decode(Bool.self, forKey: .checked)) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text.text, forKey: .text)
            try container.encodeIfPresent(text.transcriptRef, forKey: .transcriptRef)
            try container.encode(checked, forKey: .checked)
        }
    }
}

extension SummaryBlockContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case content
        case items
        case language
        case screenshotId = "screenshot_id"
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
        let type = (try? container.decode(String.self, forKey: .type)) ?? BlockType.paragraph.rawValue

        switch BlockType(rawValue: type) {
        case .paragraph:
            self = .paragraph((try? container.decode(SummaryText.self, forKey: .content)) ?? SummaryText(""))
        case .bulletedList:
            self = .bulletedList(items: (try? container.decode([SummaryText].self, forKey: .items)) ?? [])
        case .numberedList:
            self = .numberedList(items: (try? container.decode([SummaryText].self, forKey: .items)) ?? [])
        case .checklist:
            self = .checklist(items: (try? container.decode([ChecklistItem].self, forKey: .items)) ?? [])
        case .quote:
            self = .quote((try? container.decode(SummaryText.self, forKey: .content)) ?? SummaryText(""))
        case .code:
            self = .code(
                language: (try? container.decode(String.self, forKey: .language)) ?? "",
                content: (try? container.decode(SummaryText.self, forKey: .content)) ?? SummaryText("")
            )
        case .image:
            if let screenshotId = try? container.decode(UUID.self, forKey: .screenshotId) {
                self = .image(
                    screenshotId: screenshotId,
                    caption: (try? container.decode(SummaryText.self, forKey: .content)) ?? SummaryText("")
                )
            } else {
                self = .paragraph((try? container.decode(SummaryText.self, forKey: .content)) ?? SummaryText(""))
            }
        case .heading:
            self = .heading(
                level: (try? container.decode(Int.self, forKey: .level)) ?? 3,
                content: (try? container.decode(SummaryText.self, forKey: .content)) ?? SummaryText("")
            )
        case .table:
            self = .table(
                headers: (try? container.decode([SummaryText].self, forKey: .headers)) ?? [],
                rows: (try? container.decode([[SummaryText]].self, forKey: .rows)) ?? []
            )
        case nil:
            self = .paragraph((try? container.decode(SummaryText.self, forKey: .content)) ?? SummaryText(""))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .paragraph(content):
            try container.encode(BlockType.paragraph.rawValue, forKey: .type)
            try container.encode(content, forKey: .content)
        case let .bulletedList(items):
            try container.encode(BlockType.bulletedList.rawValue, forKey: .type)
            try container.encode(items, forKey: .items)
        case let .numberedList(items):
            try container.encode(BlockType.numberedList.rawValue, forKey: .type)
            try container.encode(items, forKey: .items)
        case let .checklist(items):
            try container.encode(BlockType.checklist.rawValue, forKey: .type)
            try container.encode(items, forKey: .items)
        case let .quote(content):
            try container.encode(BlockType.quote.rawValue, forKey: .type)
            try container.encode(content, forKey: .content)
        case let .code(language, content):
            try container.encode(BlockType.code.rawValue, forKey: .type)
            try container.encode(language, forKey: .language)
            try container.encode(content, forKey: .content)
        case let .image(screenshotId, caption):
            try container.encode(BlockType.image.rawValue, forKey: .type)
            try container.encode(screenshotId, forKey: .screenshotId)
            try container.encode(caption, forKey: .content)
        case let .heading(level, content):
            try container.encode(BlockType.heading.rawValue, forKey: .type)
            try container.encode(level, forKey: .level)
            try container.encode(content, forKey: .content)
        case let .table(headers, rows):
            try container.encode(BlockType.table.rawValue, forKey: .type)
            try container.encode(headers, forKey: .headers)
            try container.encode(rows, forKey: .rows)
        }
    }
}

extension SummaryBlock {
    private enum CodingKeys: String, CodingKey {
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? .v7()
        content = try SummaryBlockContent(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try content.encode(to: encoder)
    }
}
