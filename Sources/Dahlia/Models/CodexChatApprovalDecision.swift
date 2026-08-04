import Foundation

enum CodexChatApprovalDecision: Equatable, Sendable {
    case accept
    case acceptForSession
    case acceptWithExecpolicyAmendment([String])
    case decline
    case cancel

    var jsonValue: JSONValue {
        switch self {
        case .accept:
            .string("accept")
        case .acceptForSession:
            .string("acceptForSession")
        case let .acceptWithExecpolicyAmendment(amendment):
            .object([
                "acceptWithExecpolicyAmendment": .object([
                    "execpolicy_amendment": .array(amendment.map(JSONValue.string)),
                ]),
            ])
        case .decline:
            .string("decline")
        case .cancel:
            .string("cancel")
        }
    }
}
