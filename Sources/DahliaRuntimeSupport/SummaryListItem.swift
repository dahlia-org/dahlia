public struct SummaryListItem: Codable, Equatable, Sendable {
    public var text: SummaryText
    public var indent: Int

    public init(text: String, transcriptRef: TranscriptReference? = nil, indent: Int = 0) {
        self.text = SummaryText(text, transcriptRef: transcriptRef)
        self.indent = indent
    }

    public init(text: SummaryText, indent: Int = 0) {
        self.text = text
        self.indent = indent
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case transcriptRef = "transcript_ref"
        case indent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .text)
        let transcriptRef = try container.decodeIfPresent(TranscriptReference.self, forKey: .transcriptRef)
        text = SummaryText(value, transcriptRef: transcriptRef)
        indent = try container.decodeIfPresent(Int.self, forKey: .indent) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text.text, forKey: .text)
        try container.encodeIfPresent(text.transcriptRef, forKey: .transcriptRef)
        if indent != 0 {
            try container.encode(indent, forKey: .indent)
        }
    }
}
