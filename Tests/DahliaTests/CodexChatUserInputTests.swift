import Testing
@testable import Dahlia

@Suite
struct CodexChatUserInputTests {
    @Test
    func parsesGenericQuestionWithoutMistakingMCPApproval() throws {
        let event = try CodexChatService.parseTurnEvent(request())
        guard case let .userInputRequested(request) = event else {
            Issue.record("Expected a user input request")
            return
        }
        #expect(request.id == "s:request-1")
        #expect(request.questionID == "desired_outcome")
        #expect(request.options.map(\.label) == ["Next steps"])
        #expect(request.allowsOther)
    }

    @Test
    func rejectsNonblockingAndOversizedQuestions() {
        #expect(throws: CodexAppServerError.self) {
            try CodexChatService.parseTurnEvent(request(isBlocking: false))
        }
        #expect(throws: CodexAppServerError.self) {
            try CodexChatService.parseTurnEvent(request(label: String(repeating: "a", count: 121)))
        }
    }

    private func request(
        isBlocking: Bool = true,
        label: String = "Next steps"
    ) -> JSONValue {
        .object([
            "id": .string("request-1"),
            "method": .string("item/tool/requestUserInput"),
            "params": .object([
                "isBlocking": .bool(isBlocking),
                "questions": .array([.object([
                    "header": .string("Outcome"),
                    "id": .string("desired_outcome"),
                    "isOther": .bool(true),
                    "options": .array([.object([
                        "description": .string("Agree on next steps."),
                        "label": .string(label),
                    ])]),
                    "question": .string("What outcome did you want?"),
                ])]),
            ]),
        ])
    }
}
