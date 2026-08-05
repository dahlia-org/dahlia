import Foundation

enum CodexChatApprovalNormalizer {
    static let byteLimit = 20000
    static let fileLimit = 50
    private static let decisionLimit = 16
    private static let amendmentItemLimit = 50

    static func request(
        id: String,
        params: [String: JSONValue],
        kind: CodexChatApprovalRequest.Kind,
        fileChanges: [CodexChatApprovalRequest.FileChange],
        mcpToolCall: CodexChatMCPToolCall? = nil,
        sourceWasTruncated: Bool = false
    ) throws -> CodexChatApprovalRequest {
        let itemID = params["itemId"]?.stringValue
        let rawCommand = params["command"]?.stringValue
        var budget = ByteBudget(limit: byteLimit)
        let reason = budget.consume(params["reason"]?.stringValue)?.nilIfBlank
        let command = budget.consume(rawCommand)?.nilIfBlank
        let cwd = budget.consume(params["cwd"]?.stringValue)?.nilIfBlank
        let boundedChanges = boundedFileChanges(fileChanges, budget: &budget)
        let mcpServer = budget.consume(mcpToolCall?.server)?.nilIfBlank
        let mcpTool = budget.consume(mcpToolCall?.tool)?.nilIfBlank
        let mcpArguments = budget.consume(mcpToolCall?.arguments)
        let grantRoot = budget.consume(params["grantRoot"]?.stringValue)?.nilIfBlank
        let unsupportedScope = grantRoot != nil
            || nonNullValue(params["additionalPermissions"])
            || nonNullValue(params["networkApprovalContext"])
            || nonEmptyArray(params["proposedNetworkPolicyAmendments"])
            || (kind == .mcpToolCall && mcpToolCall?.server != "dahlia")
        let isTooLarge = sourceWasTruncated
            || mcpToolCall?.isTruncated == true
            || budget.didTruncate
            || fileChanges.count > fileLimit
        let hasExactPayload = switch kind {
        case .commandExecution:
            hasBoundedNonBlankText(rawCommand)
        case .fileChange:
            !fileChanges.isEmpty
        case .mcpToolCall:
            hasExactMCPToolCallPayload(mcpToolCall)
        }
        let reviewability: CodexChatApprovalRequest.Reviewability = if unsupportedScope || !hasExactPayload {
            .unsupported
        } else if isTooLarge {
            .tooLarge
        } else {
            .ready
        }

        return CodexChatApprovalRequest(
            id: id,
            itemID: itemID,
            kind: kind,
            command: command,
            cwd: cwd,
            fileChanges: boundedChanges,
            mcpServer: mcpServer,
            mcpTool: mcpTool,
            mcpArguments: mcpArguments,
            grantRoot: grantRoot,
            reason: reason,
            reviewability: reviewability,
            actions: actions(
                params: params,
                kind: kind,
                reviewability: reviewability,
                budget: &budget
            )
        )
    }

    private static func actions(
        params: [String: JSONValue],
        kind: CodexChatApprovalRequest.Kind,
        reviewability: CodexChatApprovalRequest.Reviewability,
        budget: inout ByteBudget
    ) -> [CodexChatApprovalAction] {
        let available = params["availableDecisions"]?.arrayValue.map {
            Array($0.prefix(decisionLimit))
        }
        let allows: (String) -> Bool = { decision in
            guard let available else { return true }
            return available.contains(.string(decision))
        }
        guard reviewability == .ready else {
            return allows("decline") ? [.deny] : []
        }
        var result: [CodexChatApprovalAction] = []
        if allows("accept") {
            result.append(.allowOnce)
        }
        if kind == .fileChange, allows("acceptForSession") {
            result.append(.allowSameFilesForSession)
        }
        if kind == .commandExecution,
           let amendment = execpolicyAmendment(
               params: params,
               availableDecisions: available,
               budget: &budget
           ) {
            result.append(.allowSimilarCommands(amendment: amendment))
        }
        if allows("decline") {
            result.append(.deny)
        }
        return result
    }

    private static func execpolicyAmendment(
        params: [String: JSONValue],
        availableDecisions: [JSONValue]?,
        budget: inout ByteBudget
    ) -> [String]? {
        guard let proposed = params["proposedExecpolicyAmendment"]?.arrayValue,
              !proposed.isEmpty,
              proposed.count <= amendmentItemLimit,
              let availableDecisions,
              let exact = availableDecisions.lazy.compactMap({ decision in
                  decision.objectValue?["acceptWithExecpolicyAmendment"]?
                      .objectValue?["execpolicy_amendment"]?.arrayValue
              }).first(where: { matches($0, proposed) })
        else { return nil }

        var bounded: [String] = []
        bounded.reserveCapacity(exact.count)
        for value in exact {
            guard let text = value.stringValue,
                  let text = budget.consume(text),
                  !budget.didTruncate else { return nil }
            bounded.append(text)
        }
        return bounded
    }

    private static func matches(_ lhs: [JSONValue], _ rhs: [JSONValue]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            guard let left = left.stringValue,
                  let right = right.stringValue else { return false }
            return left == right
        }
    }

    static func boundedFileChangeSnapshot(
        _ changes: [CodexChatApprovalRequest.FileChange],
        limit: Int = byteLimit
    ) -> CodexChatApprovalFileChangeSnapshot {
        var budget = ByteBudget(limit: limit)
        let bounded = boundedFileChanges(changes, budget: &budget)
        return CodexChatApprovalFileChangeSnapshot(
            changes: bounded,
            isTruncated: budget.didTruncate || changes.count > fileLimit
        )
    }

    static func boundedMCPToolCall(
        server: String,
        tool: String,
        arguments: JSONValue
    ) -> CodexChatMCPToolCall {
        var budget = ByteBudget(limit: byteLimit)
        let boundedServer = budget.consume(server)?.nilIfBlank
        let boundedTool = budget.consume(tool)?.nilIfBlank
        let encodedArguments = jsonString(arguments)
        let boundedArguments = budget.consume(encodedArguments)
        return CodexChatMCPToolCall(
            server: boundedServer,
            tool: boundedTool,
            arguments: boundedArguments,
            isTruncated: encodedArguments == nil || budget.didTruncate
        )
    }

    private static func boundedFileChanges(
        _ changes: [CodexChatApprovalRequest.FileChange],
        budget: inout ByteBudget
    ) -> [CodexChatApprovalRequest.FileChange] {
        changes.prefix(fileLimit).compactMap { change in
            let path = budget.consume(change.path)
            let diff = budget.consume(change.diff)
            let kind: CodexChatApprovalRequest.FileChange.Kind = switch change.kind {
            case .add:
                .add
            case .delete:
                .delete
            case let .update(movePath):
                .update(movePath: budget.consume(movePath))
            }
            guard let path else { return nil }
            return CodexChatApprovalRequest.FileChange(
                path: path,
                diff: diff ?? "",
                kind: kind
            )
        }
    }

    private static func nonNullValue(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        return value != .null
    }

    private static func hasBoundedNonBlankText(_ text: String?) -> Bool {
        var budget = ByteBudget(limit: byteLimit)
        return budget.consume(text)?.nilIfBlank != nil
    }

    private static func hasExactMCPToolCallPayload(_ toolCall: CodexChatMCPToolCall?) -> Bool {
        guard let toolCall else { return false }
        return hasBoundedNonBlankText(toolCall.server)
            && hasBoundedNonBlankText(toolCall.tool)
            && toolCall.arguments?.nilIfBlank != nil
    }

    private static func nonEmptyArray(_ value: JSONValue?) -> Bool {
        value?.arrayValue?.isEmpty == false
    }

    private static func jsonString(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8).map(escapingBidirectionalControls)
    }

    private static func escapingBidirectionalControls(in text: String) -> String {
        text.unicodeScalars.reduce(into: "") { result, scalar in
            switch scalar.value {
            case 0x061C, 0x200E ... 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
    }
}

private struct ByteBudget {
    private(set) var remaining: Int
    private(set) var didTruncate = false

    init(limit: Int) {
        remaining = limit
    }

    mutating func consume(_ text: String?) -> String? {
        guard let text else { return nil }
        return consume(text)
    }

    mutating func consume(_ text: String) -> String? {
        let bytes = text.utf8.prefix(remaining + 1)
        guard bytes.count > remaining else {
            remaining -= bytes.count
            return text
        }
        didTruncate = true
        guard remaining >= 3 else {
            remaining = 0
            return nil
        }
        let contentLimit = remaining - 3
        var byteCount = 0
        var end = text.unicodeScalars.startIndex
        while end < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[end]
            guard byteCount + scalar.utf8.count <= contentLimit else { break }
            byteCount += scalar.utf8.count
            end = text.unicodeScalars.index(after: end)
        }
        remaining = 0
        return String(text.unicodeScalars[..<end]) + "…"
    }
}
