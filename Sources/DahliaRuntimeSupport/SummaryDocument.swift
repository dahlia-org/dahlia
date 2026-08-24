import Foundation

/// サマリーの正準表現。アプリと MCP ヘルパーが同じ型を共有する。
public struct SummaryDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var title: String
    public var description: String
    public var sections: [SummarySection]
    public var tags: [String]
    public var actionItems: [SummaryActionItem]

    public init(
        schemaVersion: Int = 3,
        title: String,
        description: String = "",
        sections: [SummarySection],
        tags: [String] = [],
        actionItems: [SummaryActionItem] = []
    ) {
        self.schemaVersion = schemaVersion
        self.title = title
        self.description = description
        self.sections = sections
        self.tags = tags
        self.actionItems = actionItems
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case title
        case description
        case sections
        case tags
        case actionItems
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        sections = try container.decode([SummarySection].self, forKey: .sections)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        actionItems = try container.decodeIfPresent([SummaryActionItem].self, forKey: .actionItems) ?? []
    }

    /// データベースに保存する正準 JSON。アプリと MCP ヘルパーで同一のバイト列になる。
    public func databaseJSONString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try String(decoding: encoder.encode(self), as: UTF8.self)
    }

    public static func decode(databaseJSON: String) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(databaseJSON.utf8))
    }

    /// 本文の出現順。重複した参照は最初の出現位置だけ残す。
    public var orderedScreenshotIds: [UUID] {
        var seen = Set<UUID>()
        return sections.flatMap(\.blocks).compactMap { block in
            guard case let .image(screenshotId, _) = block.content,
                  seen.insert(screenshotId).inserted else { return nil }
            return screenshotId
        }
    }

    public var referencedScreenshotIds: Set<UUID> {
        Set(orderedScreenshotIds)
    }

    /// Summary body text used by local search. Metadata and reference identifiers stay out of the index.
    public var searchableBodyText: String {
        sections.flatMap { section in
            [section.heading] + section.blocks.flatMap(\.content.searchableText)
        }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n")
    }

    public func removingScreenshotReferences(_ screenshotIds: Set<UUID>) -> Self {
        guard !screenshotIds.isEmpty else { return self }

        var updated = self
        updated.sections = sections.map { section in
            var updatedSection = section
            updatedSection.blocks = section.blocks.compactMap { block in
                guard case let .image(screenshotId, caption) = block.content,
                      screenshotIds.contains(screenshotId) else {
                    return block
                }
                guard caption.text.summaryNilIfBlank != nil || caption.transcriptRef != nil else { return nil }
                return SummaryBlock(id: block.id, content: .paragraph(caption))
            }
            return updatedSection
        }
        return updated
    }
}

public struct SummarySection: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var heading: String
    public var blocks: [SummaryBlock]

    public init(id: UUID, heading: String, blocks: [SummaryBlock]) {
        self.id = id
        self.heading = heading
        self.blocks = blocks
    }
}

public struct TranscriptReference: Codable, Equatable, Sendable {
    public var time: String

    public init(time: String) {
        self.time = time
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        time = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(time)
    }
}

public struct SummaryText: Codable, Equatable, Sendable {
    public var text: String
    public var transcriptRef: TranscriptReference?

    public init(_ text: String, transcriptRef: TranscriptReference? = nil) {
        self.text = text
        self.transcriptRef = transcriptRef
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case transcriptRef = "transcript_ref"
    }
}

public struct SummaryActionItem: Codable, Equatable, Sendable {
    public let title: String
    public let assignee: String

    public init(title: String, assignee: String) {
        self.title = title
        self.assignee = assignee
    }
}

public struct SummaryBlock: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var content: SummaryBlockContent

    public init(id: UUID, content: SummaryBlockContent) {
        self.id = id
        self.content = content
    }

    /// 新しい block id を採番する。ADR-0001 のとおり id はアプリ側が採番し、LLM には生成させない。
    public init(content: SummaryBlockContent) {
        self.init(id: summaryUUIDv7(), content: content)
    }

    public typealias ChecklistItem = SummaryBlockContent.ChecklistItem

    public static func paragraph(_ text: String, transcriptRef: TranscriptReference? = nil) -> Self {
        Self(content: .paragraph(SummaryText(text, transcriptRef: transcriptRef)))
    }

    public static func paragraph(_ text: SummaryText) -> Self {
        Self(content: .paragraph(text))
    }

    public static func bulletedList(items: [String]) -> Self {
        Self(content: .bulletedList(items: items.map { SummaryText($0) }))
    }

    public static func bulletedList(items: [SummaryText]) -> Self {
        Self(content: .bulletedList(items: items))
    }

    public static func numberedList(items: [String]) -> Self {
        Self(content: .numberedList(items: items.map { SummaryText($0) }))
    }

    public static func numberedList(items: [SummaryText]) -> Self {
        Self(content: .numberedList(items: items))
    }

    public static func checklist(items: [ChecklistItem]) -> Self {
        Self(content: .checklist(items: items))
    }

    public static func quote(_ text: String, transcriptRef: TranscriptReference? = nil) -> Self {
        Self(content: .quote(SummaryText(text, transcriptRef: transcriptRef)))
    }

    public static func quote(_ text: SummaryText) -> Self {
        Self(content: .quote(text))
    }

    public static func code(language: String, code: String, transcriptRef: TranscriptReference? = nil) -> Self {
        Self(content: .code(language: language, content: SummaryText(code, transcriptRef: transcriptRef)))
    }

    public static func code(language: String, content: SummaryText) -> Self {
        Self(content: .code(language: language, content: content))
    }

    public static func image(screenshotId: UUID, caption: String, transcriptRef: TranscriptReference? = nil) -> Self {
        Self(content: .image(screenshotId: screenshotId, caption: SummaryText(caption, transcriptRef: transcriptRef)))
    }

    public static func image(screenshotId: UUID, caption: SummaryText) -> Self {
        Self(content: .image(screenshotId: screenshotId, caption: caption))
    }

    public static func heading(level: Int, text: String, transcriptRef: TranscriptReference? = nil) -> Self {
        Self(content: .heading(level: level, content: SummaryText(text, transcriptRef: transcriptRef)))
    }

    public static func heading(level: Int, content: SummaryText) -> Self {
        Self(content: .heading(level: level, content: content))
    }

    public static func table(headers: [String], rows: [[String]]) -> Self {
        Self(content: .table(headers: headers.map { SummaryText($0) }, rows: rows.map { $0.map { SummaryText($0) } }))
    }

    public static func table(headers: [SummaryText], rows: [[SummaryText]]) -> Self {
        Self(content: .table(headers: headers, rows: rows))
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.content == rhs.content
    }
}

public enum SummaryBlockContent: Equatable, Sendable {
    case paragraph(SummaryText)
    case bulletedList(items: [SummaryText])
    case numberedList(items: [SummaryText])
    case checklist(items: [ChecklistItem])
    case quote(SummaryText)
    case code(language: String, content: SummaryText)
    case image(screenshotId: UUID, caption: SummaryText)
    case heading(level: Int, content: SummaryText)
    case table(headers: [SummaryText], rows: [[SummaryText]])

    public struct ChecklistItem: Codable, Equatable, Sendable {
        public var text: SummaryText
        public var checked: Bool

        public init(text: String, transcriptRef: TranscriptReference? = nil, checked: Bool) {
            self.text = SummaryText(text, transcriptRef: transcriptRef)
            self.checked = checked
        }

        public init(text: SummaryText, checked: Bool) {
            self.text = text
            self.checked = checked
        }

        private enum CodingKeys: String, CodingKey {
            case text
            case transcriptRef = "transcript_ref"
            case checked
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let value = try container.decode(String.self, forKey: .text)
            let transcriptRef = try container.decodeIfPresent(TranscriptReference.self, forKey: .transcriptRef)
            text = SummaryText(value, transcriptRef: transcriptRef)
            checked = (try? container.decode(Bool.self, forKey: .checked)) ?? false
        }

        public func encode(to encoder: Encoder) throws {
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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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

private extension SummaryBlockContent {
    var searchableText: [String] {
        switch self {
        case let .paragraph(text), let .quote(text), let .image(_, text), let .heading(_, text):
            [text.text]
        case let .bulletedList(items), let .numberedList(items):
            items.map(\.text)
        case let .checklist(items):
            items.map(\.text.text)
        case let .code(_, content):
            [content.text]
        case let .table(headers, rows):
            (headers + rows.flatMap(\.self)).map(\.text)
        }
    }
}

public extension SummaryBlock {
    private enum CodingKeys: String, CodingKey {
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // id を持たない旧ドキュメントでも同じ block が常に同じ id になるよう、coding path から決定的に導出する。
        // ランダム採番にすると読み出しのたびに id が変わり、MCP 経由の書き戻しで block 同一性が壊れる。
        id = (try? container.decode(UUID.self, forKey: .id)) ?? Self.derivedID(codingPath: decoder.codingPath)
        content = try SummaryBlockContent(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try content.encode(to: encoder)
    }

    internal static func derivedID(codingPath: [CodingKey]) -> UUID {
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
}

/// `Sources/Dahlia` の同名ユーティリティと衝突しないよう、共有ターゲット内部だけで使う。
extension String {
    var summaryNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 共有ターゲット内部用の UUID v7 生成。`Sources/Dahlia` の `UUID.v7()` と同じレイアウト。
func summaryUUIDv7() -> UUID {
    let milliseconds = UInt64(Date().timeIntervalSince1970 * 1000)
    var bytes = (0 ..< 16).map { index -> UInt8 in
        index < 6 ? UInt8(truncatingIfNeeded: milliseconds >> UInt64((5 - index) * 8)) : UInt8.random(in: 0 ... 255)
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x70
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}
