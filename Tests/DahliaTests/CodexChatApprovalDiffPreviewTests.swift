@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatApprovalNormalizerTests {
        @Test
        func preservesAReviewableRequestWithinTheAggregateLimit() throws {
            let request = try CodexChatApprovalNormalizer.request(
                id: "s:approval",
                params: [
                    "availableDecisions": .array([
                        .string("accept"),
                        .string("acceptForSession"),
                        .string("decline"),
                    ]),
                    "command": .string("swift test"),
                    "cwd": .string("/workspace"),
                    "itemId": .string("item-1"),
                    "reason": .string("Run tests"),
                ],
                kind: .commandExecution,
                fileChanges: []
            )

            #expect(request.reviewability == .ready)
            #expect(request.itemID == "item-1")
            #expect(request.actions == [.allowOnce, .deny])
        }

        @Test
        func oversizedCommandIsBoundedAndFailClosed() throws {
            let text = String(repeating: "a", count: CodexChatApprovalNormalizer.byteLimit * 2)
            let request = try CodexChatApprovalNormalizer.request(
                id: "s:approval",
                params: ["command": .string(text), "reason": .string(text)],
                kind: .commandExecution,
                fileChanges: []
            )
            let displayedBytes = [request.reason, request.command, request.cwd]
                .compactMap(\.self)
                .reduce(0) { $0 + $1.utf8.count }

            #expect(displayedBytes <= CodexChatApprovalNormalizer.byteLimit)
            #expect(request.reviewability == .tooLarge)
            #expect(request.actions == [.deny])
        }

        @Test
        func blankNormalizationOnlyExaminesBoundedApprovalText() throws {
            let text = String(repeating: " ", count: CodexChatApprovalNormalizer.byteLimit * 100)
                + "command"
            let request = try CodexChatApprovalNormalizer.request(
                id: "s:approval",
                params: ["command": .string(text)],
                kind: .commandExecution,
                fileChanges: []
            )

            #expect((request.command?.utf8.count ?? 0) <= CodexChatApprovalNormalizer.byteLimit)
            #expect(request.reviewability == .tooLarge)
            #expect(request.actions == [.deny])
        }

        @Test
        func unsupportedPermissionScopeCannotBeApproved() throws {
            let request = try CodexChatApprovalNormalizer.request(
                id: "s:approval",
                params: [
                    "command": .string("cat /outside/file"),
                    "grantRoot": .string("/outside"),
                ],
                kind: .commandExecution,
                fileChanges: []
            )

            #expect(request.reviewability == .unsupported)
            #expect(request.actions == [.deny])
        }

        @Test
        func structuredExecpolicyDecisionUsesTheServerAmendment() throws {
            let amendment = ["git", "status"]
            let request = try CodexChatApprovalNormalizer.request(
                id: "s:approval",
                params: [
                    "availableDecisions": .array([
                        .string("accept"),
                        .string("decline"),
                        .object([
                            "acceptWithExecpolicyAmendment": .object([
                                "execpolicy_amendment": .array(amendment.map(JSONValue.string)),
                            ]),
                        ]),
                    ]),
                    "command": .string("git status"),
                    "proposedExecpolicyAmendment": .array(amendment.map(JSONValue.string)),
                ],
                kind: .commandExecution,
                fileChanges: []
            )

            #expect(request.actions == [
                .allowOnce,
                .allowSimilarCommands(amendment: amendment),
                .deny,
            ])
            #expect(request.actions[1].decision.jsonValue == .object([
                "acceptWithExecpolicyAmendment": .object([
                    "execpolicy_amendment": .array(amendment.map(JSONValue.string)),
                ]),
            ]))
        }

        @Test
        func mismatchedOrOversizedExecpolicyAmendmentIsNotOffered() throws {
            let mismatched = try CodexChatApprovalNormalizer.request(
                id: "s:mismatched",
                params: [
                    "availableDecisions": .array([
                        .string("accept"),
                        .string("decline"),
                        .object([
                            "acceptWithExecpolicyAmendment": .object([
                                "execpolicy_amendment": .array([.string("git"), .string("status")]),
                            ]),
                        ]),
                    ]),
                    "command": .string("git status"),
                    "proposedExecpolicyAmendment": .array([.string("git"), .string("diff")]),
                ],
                kind: .commandExecution,
                fileChanges: []
            )
            let oversized = try CodexChatApprovalNormalizer.request(
                id: "s:oversized",
                params: [
                    "availableDecisions": .array([
                        .string("accept"),
                        .string("decline"),
                        .object([
                            "acceptWithExecpolicyAmendment": .object([
                                "execpolicy_amendment": .array(
                                    (0 ... CodexChatApprovalNormalizer.fileLimit).map { .string("rule-\($0)") }
                                ),
                            ]),
                        ]),
                    ]),
                    "command": .string("git status"),
                    "proposedExecpolicyAmendment": .array(
                        (0 ... CodexChatApprovalNormalizer.fileLimit).map { .string("rule-\($0)") }
                    ),
                ],
                kind: .commandExecution,
                fileChanges: []
            )

            #expect(mismatched.actions == [.allowOnce, .deny])
            #expect(oversized.actions == [.allowOnce, .deny])
        }

        @Test
        func failClosedRequestOnlyOffersDeclineWhenTheServerAllowsIt() throws {
            let request = try CodexChatApprovalNormalizer.request(
                id: "s:approval",
                params: [
                    "availableDecisions": .array([.string("accept")]),
                    "command": .string(String(repeating: "a", count: CodexChatApprovalNormalizer.byteLimit + 1)),
                ],
                kind: .commandExecution,
                fileChanges: []
            )

            #expect(request.reviewability == .tooLarge)
            #expect(request.actions.isEmpty)
        }

        @Test
        func truncatedFileChangeSourceIsFailClosed() throws {
            let snapshot = CodexChatApprovalNormalizer.boundedFileChangeSnapshot([
                .init(
                    path: "Large.swift",
                    diff: String(repeating: "+line\n", count: CodexChatApprovalNormalizer.byteLimit)
                ),
            ])
            let request = try CodexChatApprovalNormalizer.request(
                id: "s:approval",
                params: [:],
                kind: .fileChange,
                fileChanges: snapshot.changes,
                sourceWasTruncated: snapshot.isTruncated
            )

            #expect(snapshot.isTruncated)
            #expect(request.reviewability == .tooLarge)
            #expect(request.actions == [.deny])
        }
    }
#endif
