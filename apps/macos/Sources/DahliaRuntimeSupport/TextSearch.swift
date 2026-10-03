import Foundation

public struct TextSearchPage: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public let id: UUID
        public let meetingId: UUID
        public let snippet: String
    }

    public let version: Int
    public let scope: String
    public let items: [Item]
    public let nextCursor: String?
}

public enum TextSearchKind: String, Codable, Sendable { case meeting, screenshot }
