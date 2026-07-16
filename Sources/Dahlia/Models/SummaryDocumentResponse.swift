import Foundation

struct SummaryDocumentResponse: Decodable {
    let title: String
    let description: String
    let sections: [SectionDTO]
    let tags: [String]
    let actionItems: [SummaryActionItem]

    struct SectionDTO: Decodable {
        let heading: String
        let blocks: [BlockDTO]
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
        tags = try container.decode([String].self, forKey: .tags)
        actionItems = try container.decode([SummaryActionItem].self, forKey: .actionItems)
    }
}
