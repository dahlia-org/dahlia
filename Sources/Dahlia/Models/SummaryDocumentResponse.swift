import Foundation

struct SummaryDocumentResponse: Decodable {
    let title: String
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

    static let responseFormat: LLMService.ResponseFormat = {
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
                "title": ["type": "string"],
                "sections": [
                    "type": "array",
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
                    "items": ["type": "string"],
                ],
                "action_items": [
                    "type": "array",
                    "items": actionItemSchema,
                ],
            ],
            "required": ["title", "sections", "tags", "action_items"],
            "additionalProperties": false,
        ]
        let schemaData = try! JSONSerialization.data(withJSONObject: schema)
        return LLMService.ResponseFormat(
            type: "json_schema",
            json_schema: .init(name: "summary_document", strict: true, schemaData: schemaData)
        )
    }()

    private enum CodingKeys: String, CodingKey {
        case title
        case sections
        case tags
        case actionItems = "action_items"
    }
}
