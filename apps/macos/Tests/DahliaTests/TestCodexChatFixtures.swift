@testable import Dahlia

enum TestCodexChatFixtures {
    static let liveTranscriptContext = """
    <context>
      Live mode is enabled. You are receiving finalized live transcription from Dahlia.
      This turn contains one hidden live transcript block.
    </context>
    """

    private static let historyUserPrompt = """
    <context>
      You are viewing a meeting in the Dahlia App.
      Type: Meeting
      <meeting_id>AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA</meeting_id>
      <meeting_name>History meeting</meeting_name>
    </context>Question
    """

    nonisolated static let historyImageDataURI =
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl2sAAAAASUVORK5CYII="

    private nonisolated static var historyImageInput: JSONValue {
        .object([
            "type": .string("image"),
            "url": .string(historyImageDataURI),
        ])
    }

    nonisolated static var modelList: JSONValue {
        .object([
            "data": .array([
                .object([
                    "id": .string("default"),
                    "model": .string("default-model"),
                    "displayName": .string("Default"),
                    "description": .string("Default model"),
                    "hidden": .bool(false),
                    "isDefault": .bool(true),
                    "supportedReasoningEfforts": .array([
                        .object([
                            "reasoningEffort": .string("medium"),
                            "description": .string("Balanced"),
                        ]),
                        .object([
                            "reasoningEffort": .string("high"),
                            "description": .string("Deep"),
                        ]),
                    ]),
                    "defaultReasoningEffort": .string("medium"),
                    "inputModalities": .array([.string("text")]),
                ]),
            ]),
            "nextCursor": .null,
        ])
    }

    nonisolated static func chatThread(id: String) -> JSONValue {
        .object([
            "id": .string(id),
            "preview": .string("Previous chat"),
            "turns": .array([
                .object([
                    "id": .string("turn-history"),
                    "status": .string("completed"),
                    "items": .array([
                        .object([
                            "id": .string("user-1"),
                            "type": .string("userMessage"),
                            "content": .array([
                                .object([
                                    "type": .string("text"),
                                    "text": .string(historyUserPrompt),
                                ]),
                                historyImageInput,
                            ]),
                        ]),
                        .object([
                            "id": .string("user-image-only"),
                            "type": .string("userMessage"),
                            "content": .array([historyImageInput]),
                        ]),
                        .object([
                            "id": .string("agent-1"),
                            "type": .string("agentMessage"),
                            "text": .string("Answer"),
                        ]),
                        .object([
                            "id": .string("reasoning-1"),
                            "type": .string("reasoning"),
                            "summary": .array([
                                .object([
                                    "type": .string("summary_text"),
                                    "text": .string("Reviewed the question"),
                                ]),
                                .object([
                                    "type": .string("summary_text"),
                                    "text": .string("Prepared the answer"),
                                ]),
                            ]),
                            "content": .array([]),
                        ]),
                    ]),
                ]),
                .object([
                    "id": .string("turn-reasoning-only"),
                    "status": .string("interrupted"),
                    "items": .array([
                        .object([
                            "id": .string("reasoning-only-1"),
                            "type": .string("reasoning"),
                            "summary": .array([
                                .object([
                                    "type": .string("summary_text"),
                                    "text": .string("Reasoning without an answer"),
                                ]),
                            ]),
                            "content": .array([]),
                        ]),
                    ]),
                ]),
            ]),
        ])
    }
}
