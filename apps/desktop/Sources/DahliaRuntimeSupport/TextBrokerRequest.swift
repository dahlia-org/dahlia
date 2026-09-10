import Foundation

/// Content IPC carries scoped requests and results, never authentication material.
public struct TextBrokerRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case meeting, transcript, touch, search, liveMeetings, liveTranscript }
    public let operation: Operation
    public let meetingId: UUID?
    public let entity: TextContentEntity?
    public let query: String?
    public let kind: TextSearchKind?
    public let cursor: String?
    public let limit: Int
    public let fromElapsedSeconds: Double?
    public let toElapsedSeconds: Double?

    public init(
        operation: Operation,
        meetingId: UUID? = nil,
        entity: TextContentEntity? = nil,
        query: String? = nil,
        kind: TextSearchKind? = nil,
        cursor: String? = nil,
        limit: Int = 200,
        fromElapsedSeconds: Double? = nil,
        toElapsedSeconds: Double? = nil
    ) {
        self.operation = operation
        self.meetingId = meetingId
        self.entity = entity
        self.query = query
        self.kind = kind
        self.cursor = cursor
        self.limit = limit
        self.fromElapsedSeconds = fromElapsedSeconds
        self.toElapsedSeconds = toElapsedSeconds
    }
}

public struct RemoteTextSearchResults: Codable, Equatable, Sendable {
    public let scope: String
    public let items: [TextSearchPage.Item]
    public let nextCursor: String?
    public let complete: Bool
    public let error: String?

    public init(items: [TextSearchPage.Item], nextCursor: String?, complete: Bool, error: String? = nil) {
        scope = "server"
        self.items = items
        self.nextCursor = nextCursor
        self.complete = complete
        self.error = error
    }
}
