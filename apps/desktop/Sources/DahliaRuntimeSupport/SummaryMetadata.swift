import Foundation

/// Generation provenance shared with Server. Response fields keep the Responses API wire names.
public struct SummaryMetadata: Codable, Equatable, Sendable {
    public var generatedBy: String
    public var inputTypes: [String]
    public var detailLevel: String?
    public var outputLanguage: String?
    public var request: Request
    public var response: Response?

    public init(
        generatedBy: String,
        inputTypes: [String],
        detailLevel: String?,
        outputLanguage: String?,
        request: Request,
        response: Response? = nil
    ) {
        self.generatedBy = generatedBy
        self.inputTypes = inputTypes
        self.detailLevel = detailLevel.map(Self.normalizedDetailLevel)
        self.outputLanguage = outputLanguage
        self.request = request
        self.response = response
    }

    public static func normalizedDetailLevel(_ value: String) -> String {
        switch value {
        case "concise": "low"
        case "standard": "medium"
        case "detailed": "high"
        case "eventSession": "xhigh"
        default: value
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        generatedBy = try values.decode(String.self, forKey: .generatedBy)
        inputTypes = try values.decode([String].self, forKey: .inputTypes)
        detailLevel = try values.decodeIfPresent(String.self, forKey: .detailLevel).map(Self.normalizedDetailLevel)
        outputLanguage = try values.decodeIfPresent(String.self, forKey: .outputLanguage)
        request = try values.decode(Request.self, forKey: .request)
        response = try values.decodeIfPresent(Response.self, forKey: .response)
    }

    public struct Reasoning: Codable, Equatable, Sendable {
        public var effort: String?
        public var summary: String?

        public init(effort: String?, summary: String? = nil) {
            self.effort = effort
            self.summary = summary
        }
    }

    public struct Request: Codable, Equatable, Sendable {
        public var model: String?
        public var reasoning: Reasoning?

        public init(model: String?, reasoning: Reasoning?) {
            self.model = model
            self.reasoning = reasoning
        }
    }

    public struct Response: Codable, Equatable, Sendable {
        public var id: String?
        public var model: String?
        public var createdAt: Double?
        public var reasoning: Reasoning?
        public var usage: Usage?

        private enum CodingKeys: String, CodingKey {
            case id, model, reasoning, usage
            case createdAt = "created_at"
        }
    }

    public struct Usage: Codable, Equatable, Sendable {
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var totalTokens: Int?
        public var inputTokensDetails: InputTokensDetails?
        public var outputTokensDetails: OutputTokensDetails?

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case totalTokens = "total_tokens"
            case inputTokensDetails = "input_tokens_details"
            case outputTokensDetails = "output_tokens_details"
        }
    }

    public struct InputTokensDetails: Codable, Equatable, Sendable {
        public var cachedTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }

    public struct OutputTokensDetails: Codable, Equatable, Sendable {
        public var reasoningTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
        }
    }
}
