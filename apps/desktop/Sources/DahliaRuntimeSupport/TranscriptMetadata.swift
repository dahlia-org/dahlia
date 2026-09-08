import Foundation

/// Provider-neutral provenance for a complete transcript, including appended recording runs.
public struct TranscriptMetadata: Codable, Equatable, Sendable {
    public var provider: String
    public var request: Request
    public var runs: [Run]

    public struct Request: Codable, Equatable, Sendable {
        public var model: String
        public init(model: String) { self.model = model }
    }

    public struct Language: Codable, Equatable, Sendable {
        public var mode: String
        public var locales: [String]
        public init(mode: String, locales: [String]) {
            self.mode = mode
            self.locales = locales
        }
    }

    public struct Run: Codable, Equatable, Sendable {
        public var generatedBy: String
        public var inputTypes: [String]
        public var startedAt: Date?
        public var completedAt: Date?
        public var language: Language?
        public var recognitionLocales: [String]?
        public var response: SummaryMetadata.Response?

        public init(
            generatedBy: String = "desktop",
            startedAt: Date?,
            completedAt: Date? = nil,
            language: Language? = nil,
            recognitionLocales: [String]? = nil
        ) {
            self.generatedBy = generatedBy
            self.inputTypes = ["audio"]
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.language = language
            self.recognitionLocales = recognitionLocales
        }
    }

    public init(provider: String, model: String, runs: [Run]) {
        self.provider = provider
        self.request = Request(model: model)
        self.runs = runs
    }

    public func usesAppleModel(_ model: String) -> Bool {
        provider == "apple" && request.model == model
    }
}

/// The body belongs to a single version; Desktop retains only this current descriptor.
public struct TranscriptInfo: Codable, Equatable, Sendable {
    public var id: UUID
    public var version: Int?
    public var syncRevision: Int?
    public var startedAt: Date?
    public var endedAt: Date?
    public var createdAt: Date?
    public var latestSegmentCreatedAt: Date?
    public var metadata: TranscriptMetadata?

    public static let activityWindow: TimeInterval = {
        // App (Contents/MacOS) and bundled MCP (Contents/Helpers) share Contents/Resources.
        let embeddedURL = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Dahlia_DahliaRuntimeSupport.bundle")
        let bundle = embeddedURL.flatMap(Bundle.init(url:)) ?? .module
        guard let url = bundle.url(forResource: "TranscriptPolicy", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let policy = try? JSONDecoder().decode([String: Double].self, from: data),
              let window = policy["activityWindowSeconds"] else {
            preconditionFailure("Missing transcript activity policy")
        }
        return window
    }()

    public var status: String { status(at: .now) }

    public func status(at now: Date) -> String {
        if endedAt != nil { return "ended" }
        guard let latestSegmentCreatedAt else { return "unknown" }
        return now.timeIntervalSince(latestSegmentCreatedAt) <= Self.activityWindow ? "active" : "inactive"
    }

    public init(id: UUID, startedAt: Date?, endedAt: Date?, metadata: TranscriptMetadata?) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.metadata = metadata
    }

    /// v49 is registered and immutable; retain its constructor until that migration has run.
    public init(id: UUID, status _: String, startedAt: Date?, completedAt: Date?, metadata: TranscriptMetadata?) {
        self.init(id: id, startedAt: startedAt, endedAt: completedAt, metadata: metadata)
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, syncRevision, startedAt, endedAt, createdAt, latestSegmentCreatedAt, metadata
    }

    private enum StatusKey: String, CodingKey { case status }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(version, forKey: .version)
        try values.encodeIfPresent(syncRevision, forKey: .syncRevision)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(endedAt, forKey: .endedAt)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(latestSegmentCreatedAt, forKey: .latestSegmentCreatedAt)
        try values.encode(metadata, forKey: .metadata)
        var state = encoder.container(keyedBy: StatusKey.self)
        try state.encode(status, forKey: .status)
    }
}
