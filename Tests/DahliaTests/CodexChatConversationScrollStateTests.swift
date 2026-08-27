@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatConversationScrollStateTests {
        @Test
        func followsOnlyWhileAtBottom() {
            #expect(CodexChatConversationScrollState(isAtBottom: true).updatedFollowState(
                previous: false,
                isResizing: false
            ))
            #expect(!CodexChatConversationScrollState(isAtBottom: false).updatedFollowState(
                previous: true,
                isResizing: false
            ))
        }

        @Test
        func resizingPreservesTheExistingFollowState() {
            let state = CodexChatConversationScrollState(isAtBottom: false)

            #expect(state.updatedFollowState(previous: true, isResizing: true))
            #expect(!state.updatedFollowState(previous: false, isResizing: true))
        }
    }
#endif
