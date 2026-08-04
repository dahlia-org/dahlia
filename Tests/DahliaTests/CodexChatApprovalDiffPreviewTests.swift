@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatApprovalDetailsProjectionTests {
        @Test
        func preservesPreviewAtTheAggregateByteLimit() {
            let path = "file.swift"
            let diff = String(repeating: "a", count: CodexChatApprovalDetailsProjection.byteLimit - path.utf8.count)
            let request = CodexChatApprovalRequest(
                id: "approval",
                kind: .fileChange,
                fileChanges: [.init(path: path, diff: diff)]
            )

            let projection = CodexChatApprovalDetailsProjection.projection(for: request)

            #expect(projection.fileChanges == [.init(path: path, diff: diff)])
            #expect(!projection.areFileChangesTruncated)
        }

        @Test
        func boundsAggregateBytesWithoutChangingRawChanges() {
            let diff = String(repeating: "a", count: CodexChatApprovalDetailsProjection.byteLimit * 100)
            let request = CodexChatApprovalRequest(
                id: "approval",
                kind: .fileChange,
                fileChanges: [
                    .init(path: "first.swift", diff: diff),
                    .init(path: "second.swift", diff: diff),
                ],
                grantRoot: diff,
                reason: diff
            )

            let projection = CodexChatApprovalDetailsProjection.projection(for: request)
            let displayedBytes = [projection.reason, projection.grantRoot]
                .compactMap(\.self)
                .reduce(0) { $0 + $1.utf8.count }
                + projection.fileChanges.reduce(0) { result, item in
                    result + item.path.utf8.count + (item.diff?.utf8.count ?? 0)
                }

            #expect(displayedBytes <= CodexChatApprovalDetailsProjection.byteLimit)
            #expect(projection.areFileChangesTruncated)
            #expect(request.fileChanges[0].diff == diff)
            #expect(request.fileChanges[1].diff == diff)
            #expect(request.grantRoot == diff)
            #expect(request.reason == diff)
        }

        @Test
        func limitsDisplayedFileCount() {
            let changes = (0 ... CodexChatApprovalDetailsProjection.fileLimit).map { index in
                CodexChatApprovalRequest.FileChange(path: "file-\(index).swift", diff: "+change")
            }
            let request = CodexChatApprovalRequest(id: "approval", kind: .fileChange, fileChanges: changes)

            let projection = CodexChatApprovalDetailsProjection.projection(for: request)

            #expect(projection.fileChanges.count == CodexChatApprovalDetailsProjection.fileLimit)
            #expect(projection.areFileChangesTruncated)
        }

        @Test
        func boundsCommandDetailsWithoutChangingRawRequest() {
            let text = String(repeating: "a", count: CodexChatApprovalDetailsProjection.byteLimit * 100)
            let request = CodexChatApprovalRequest(
                id: "approval",
                kind: .commandExecution,
                command: text,
                cwd: text,
                reason: text
            )

            let projection = CodexChatApprovalDetailsProjection.projection(for: request)
            let displayedBytes = [projection.reason, projection.command, projection.cwd]
                .compactMap(\.self)
                .reduce(0) { $0 + $1.utf8.count }

            #expect(displayedBytes <= CodexChatApprovalDetailsProjection.byteLimit)
            #expect(request.command == text)
            #expect(request.cwd == text)
            #expect(request.reason == text)
        }
    }
#endif
