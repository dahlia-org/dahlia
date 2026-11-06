import DahliaRuntimeSupport
import Foundation

/// Providers that see the schema only in the prompt (Claude, Gemini) may leave out fields that are empty for them, so
/// decoding requires only what carries the summary: the title, each section's heading, each block's type and the field
/// its type carries text in, item text, and action item titles. Every other field takes its empty value when missing.
struct SummaryDocumentResponse: Decodable {
    let title: String
    let description: String
    let sections: [SectionDTO]
    let tags: [String]
    let actionItems: [SummaryActionItem]

    struct SectionDTO: Decodable {
        let heading: String
        let blocks: [BlockDTO]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            heading = try container.decode(String.self, forKey: .heading)
            blocks = try container.decodeIfPresent([BlockDTO].self, forKey: .blocks) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case heading
            case blocks
        }
    }

    private struct ActionItemDTO: Decodable {
        let title: String
        let assignee: String?
    }

    struct BlockDTO: Decodable {
        let type: String
        let level: Int
        let content: TextDTO
        let items: [ItemDTO]
        let language: String
        let imageId: String

        private enum CodingKeys: String, CodingKey {
            case type
            case level
            case content
            case items
            case language
            case imageId = "image_id"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            let isList = ["bulleted_list", "numbered_list", "checklist"].contains(type)
            level = try container.decodeIfPresent(Int.self, forKey: .level) ?? 0
            content = if isList || type == "image" {
                try container.decodeIfPresent(TextDTO.self, forKey: .content) ?? TextDTO(text: "", transcriptRef: nil)
            } else {
                try container.decode(TextDTO.self, forKey: .content)
            }
            items = if isList {
                try container.decode([ItemDTO].self, forKey: .items)
            } else {
                try container.decodeIfPresent([ItemDTO].self, forKey: .items) ?? []
            }
            language = try container.decodeIfPresent(String.self, forKey: .language) ?? ""
            imageId = try container.decodeIfPresent(String.self, forKey: .imageId) ?? ""
        }
    }

    struct TextDTO: Decodable {
        let text: String
        let transcriptRef: String?

        private enum CodingKeys: String, CodingKey {
            case text
            case transcriptRef = "transcript_ref"
        }
    }

    struct ItemDTO: Decodable {
        let text: String
        let transcriptRef: String?
        let checked: Bool

        private enum CodingKeys: String, CodingKey {
            case text
            case transcriptRef = "transcript_ref"
            case checked
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            transcriptRef = try container.decodeIfPresent(String.self, forKey: .transcriptRef)
            checked = try container.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        }
    }

    static let outputSchema: Data = {
        let summaryTextSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "text": ["type": "string"],
                "transcript_ref": ["type": ["string", "null"]],
            ],
            "required": ["text", "transcript_ref"],
            "additionalProperties": false,
        ]
        let itemSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "text": ["type": "string"],
                "transcript_ref": ["type": ["string", "null"]],
                "checked": ["type": "boolean"],
            ],
            "required": ["text", "transcript_ref", "checked"],
            "additionalProperties": false,
        ]
        let blockSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "type": [
                    "type": "string",
                    "enum": [
                        "paragraph",
                        "bulleted_list",
                        "numbered_list",
                        "checklist",
                        "quote",
                        "code",
                        "image",
                        "heading",
                    ],
                ],
                "level": ["type": "integer"],
                "content": summaryTextSchema,
                "items": [
                    "type": "array",
                    "items": itemSchema,
                ],
                "language": ["type": "string"],
                "image_id": ["type": "string"],
            ],
            "required": ["type", "level", "content", "items", "language", "image_id"],
            "additionalProperties": false,
        ]
        let actionItemSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "assignee": ["type": "string"],
            ],
            "required": ["title", "assignee"],
            "additionalProperties": false,
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 120,
                ],
                "description": [
                    "type": "string",
                    "description": "A one-line description for quickly identifying the meeting.",
                    "minLength": 1,
                    "maxLength": 240,
                ],
                "sections": [
                    "type": "array",
                    "description": "Summary body sections only. Do not include an Action Items section or repeat action items here.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "heading": ["type": "string"],
                            "blocks": [
                                "type": "array",
                                "items": blockSchema,
                            ],
                        ],
                        "required": ["heading", "blocks"],
                        "additionalProperties": false,
                    ],
                ],
                "tags": [
                    "type": "array",
                    "items": [
                        "type": "string",
                        "pattern": "^[a-z0-9_]*[a-z][a-z0-9_]*$",
                    ],
                ],
                "action_items": [
                    "type": "array",
                    "description": "The only location for concrete action items.",
                    "items": actionItemSchema,
                ],
            ],
            "required": ["title", "description", "sections", "tags", "action_items"],
            "additionalProperties": false,
        ]
        guard let schemaData = try? JSONSerialization.data(withJSONObject: schema) else {
            preconditionFailure("Summary JSON schema must be serializable")
        }
        return schemaData
    }()

    private enum CodingKeys: String, CodingKey {
        case title
        case description
        case sections
        case tags
        case actionItems = "action_items"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        sections = try container.decode([SectionDTO].self, forKey: .sections)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        actionItems = try (container.decodeIfPresent([ActionItemDTO].self, forKey: .actionItems) ?? [])
            .map { SummaryActionItem(title: $0.title, assignee: $0.assignee ?? "") }
    }
}
