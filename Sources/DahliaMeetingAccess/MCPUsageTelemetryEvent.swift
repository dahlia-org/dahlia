import Foundation

public struct MCPUsageTelemetryEvent: Equatable, Sendable {
    public enum Origin: String, Sendable {
        case codexChat
    }

    public enum Category: String, Sendable {
        case meeting
        case project
        case customerIntelligence
        case unknown
    }

    public enum Operation: String, Sendable {
        case read
        case write
    }

    public enum Outcome: String, Sendable {
        case completed
        case failed
    }

    public let origin: Origin
    public let category: Category
    public let operation: Operation
    public let outcome: Outcome

    public var signalName: String {
        "Dahlia.MCP.ToolCall.\(outcome.rawValue)"
    }

    public var parameters: [String: String] {
        [
            "origin": origin.rawValue,
            "category": category.rawValue,
            "operation": operation.rawValue,
        ]
    }
}
