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
        let text: String
        let items: [ItemDTO]
        let language: String
        let imageId: String

        private enum CodingKeys: String, CodingKey {
            case type
            case level
            case text
            case items
            case language
            case imageId = "image_id"
        }
    }

    struct ItemDTO: Decodable {
        let text: String
        let checked: Bool
    }

    static let responseFormat: LLMService.ResponseFormat = {
        let checklistItemSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "text": ["type": "string"],
                "checked": ["type": "boolean"],
            ],
            "required": ["text", "checked"],
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
                "text": ["type": "string"],
                "items": [
                    "type": "array",
                    "items": checklistItemSchema,
                ],
                "language": ["type": "string"],
                "image_id": ["type": "string"],
            ],
            "required": ["type", "level", "text", "items", "language", "image_id"],
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
