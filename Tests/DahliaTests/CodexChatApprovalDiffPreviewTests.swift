@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatApprovalDiffPreviewTests {
        @Test
        func preservesDiffsAtTheByteLimit() {
            let diff = String(repeating: "a", count: CodexChatApprovalDiffPreview.byteLimit)

            #expect(CodexChatApprovalDiffPreview.text(for: diff) == diff)
        }

        @Test
        func truncatesRenderedPreviewWithoutChangingTheRawDiff() {
            let visible = String(repeating: "a", count: CodexChatApprovalDiffPreview.byteLimit)
            let diff = visible + "bc"

            #expect(CodexChatApprovalDiffPreview.text(for: diff) == visible + "\n…")
            #expect(diff == visible + "bc")
        }
    }
#endif
