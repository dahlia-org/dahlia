@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatApprovalDiffPreviewTests {
        @Test
        func preservesPreviewAtTheAggregateByteLimit() {
            let path = "file.swift"
            let diff = String(repeating: "a", count: CodexChatApprovalDiffPreview.byteLimit - path.utf8.count)
            let changes = [CodexChatApprovalRequest.FileChange(path: path, diff: diff)]

            let preview = CodexChatApprovalDiffPreview.projection(for: changes)

            #expect(preview.items == [.init(path: path, diff: diff)])
            #expect(!preview.isTruncated)
        }

        @Test
        func boundsAggregateBytesWithoutChangingRawChanges() {
            let diff = String(repeating: "a", count: CodexChatApprovalDiffPreview.byteLimit)
            let changes = [
                CodexChatApprovalRequest.FileChange(path: "first.swift", diff: diff),
                CodexChatApprovalRequest.FileChange(path: "second.swift", diff: diff),
            ]

            let preview = CodexChatApprovalDiffPreview.projection(for: changes)
            let displayedBytes = preview.items.reduce(0) { result, item in
                result + item.path.utf8.count + (item.diff?.utf8.count ?? 0)
            }

            #expect(displayedBytes <= CodexChatApprovalDiffPreview.byteLimit)
            #expect(preview.isTruncated)
            #expect(changes[0].diff == diff)
            #expect(changes[1].diff == diff)
        }

        @Test
        func limitsDisplayedFileCount() {
            let changes = (0 ... CodexChatApprovalDiffPreview.fileLimit).map { index in
                CodexChatApprovalRequest.FileChange(path: "file-\(index).swift", diff: "+change")
            }

            let preview = CodexChatApprovalDiffPreview.projection(for: changes)

            #expect(preview.items.count == CodexChatApprovalDiffPreview.fileLimit)
            #expect(preview.isTruncated)
        }
    }
#endif
