import Foundation

enum CodexChatApprovalNormalizer {
    static let byteLimit = 20000
    static let fileLimit = 50

    static func request(
        id: String,
        params: [String: JSONValue],
        kind: CodexChatApprovalRequest.Kind,
        fileChanges: [CodexChatApprovalRequest.FileChange],
        sourceWasTruncated: Bool = false
    ) throws -> CodexChatApprovalRequest {
        let itemID = params["itemId"]?.stringValue
        let rawReason = params["reason"]?.stringValue?.nilIfBlank
        let rawCommand = params["command"]?.stringValue?.nilIfBlank
        let rawCWD = params["cwd"]?.stringValue?.nilIfBlank
        let rawGrantRoot = params["grantRoot"]?.stringValue?.nilIfBlank
        let unsupportedScope = rawGrantRoot != nil
            || nonNullValue(params["additionalPermissions"])
            || nonNullValue(params["networkApprovalContext"])
            || nonEmptyArray(params["proposedNetworkPolicyAmendments"])

        var budget = ByteBudget(limit: byteLimit)
        let reason = budget.consume(rawReason)
        let command = budget.consume(rawCommand)
        let cwd = budget.consume(rawCWD)
        let boundedChanges = boundedFileChanges(fileChanges, budget: &budget)
        let grantRoot = budget.consume(rawGrantRoot)
        let isTooLarge = sourceWasTruncated || budget.didTruncate || fileChanges.count > fileLimit
        let hasExactPayload = switch kind {
        case .commandExecution:
            rawCommand != nil
        case .fileChange:
            !fileChanges.isEmpty
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
            grantRoot: grantRoot,
            reason: reason,
            reviewability: reviewability,
            actions: actions(
                params: params,
                kind: kind,
                reviewability: reviewability
            )
        )
    }

    private static func actions(
        params: [String: JSONValue],
        kind: CodexChatApprovalRequest.Kind,
        reviewability: CodexChatApprovalRequest.Reviewability
    ) -> [CodexChatApprovalAction] {
        guard reviewability == .ready else { return [.deny] }
        let available = params["availableDecisions"]?.arrayValue
        let allows: (String) -> Bool = { decision in
            guard let available else { return true }
            return available.contains(.string(decision))
        }
        var result: [CodexChatApprovalAction] = []
        if allows("accept") {
            result.append(.allowOnce)
        }
        if allows("acceptForSession") {
            result.append(.allowForSession)
        }
        if kind == .commandExecution,
           let amendment = params["proposedExecpolicyAmendment"]?.arrayValue?.compactMap(\.stringValue),
           !amendment.isEmpty,
           available?.contains(where: supportsExecpolicyAmendment) == true {
            result.append(.allowSimilarCommands(amendment: amendment))
        }
        if allows("decline") {
            result.append(.deny)
        }
        return result
    }

    private static func supportsExecpolicyAmendment(_ value: JSONValue) -> Bool {
        value == .string("acceptWithExecpolicyAmendment")
            || value.objectValue?["acceptWithExecpolicyAmendment"] != nil
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

    private static func boundedFileChanges(
        _ changes: [CodexChatApprovalRequest.FileChange],
        budget: inout ByteBudget
    ) -> [CodexChatApprovalRequest.FileChange] {
        changes.prefix(fileLimit).compactMap { change in
            let path = budget.consume(change.path)
            let diff = budget.consume(change.diff)
            guard let path else { return nil }
            return CodexChatApprovalRequest.FileChange(path: path, diff: diff ?? "")
        }
    }

    private static func nonNullValue(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        return value != .null
    }

    private static func nonEmptyArray(_ value: JSONValue?) -> Bool {
        value?.arrayValue?.isEmpty == false
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
