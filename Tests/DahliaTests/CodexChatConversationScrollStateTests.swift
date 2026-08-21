@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatConversationScrollStateTests {
        @Test
        func contentGrowthRestoresOnlyAnActiveBottomFollow() {
            let previous = CodexChatConversationScrollState(contentHeight: 100, isAtBottom: true)
            let current = CodexChatConversationScrollState(contentHeight: 140, isAtBottom: false)

            #expect(current.shouldRestoreFollow(from: previous, isFollowingLatest: true))
            #expect(!current.shouldRestoreFollow(from: previous, isFollowingLatest: false))
        }
    }
#endif
