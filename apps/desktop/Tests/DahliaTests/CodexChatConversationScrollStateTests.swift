@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexChatConversationScrollStateTests {
        @Test
        func conversationWindowPagesWithoutMaterializingTheWholeHistory() {
            var window = CodexChatConversationWindow()
            let messages = alternatingMessages(count: 100)
            let ranges = CodexChatConversationWindow.pageRanges(in: messages)

            #expect(window.visibleRange(in: ranges) == 80 ..< 100)
            #expect(window.hasEarlierMessages(in: ranges))
            #expect(!window.hasLaterMessages(in: ranges))

            window.showEarlierMessages(in: ranges)
            #expect(window.visibleRange(in: ranges) == 40 ..< 80)
            #expect(window.hasEarlierMessages(in: ranges))
            #expect(window.hasLaterMessages(in: ranges))

            window.showEarlierMessages(in: ranges)
            #expect(window.visibleRange(in: ranges) == 0 ..< 40)
            #expect(!window.hasEarlierMessages(in: ranges))

            window.showLaterMessages(in: ranges)
            #expect(window.visibleRange(in: ranges) == 40 ..< 80)

            window.showLatestMessages()
            #expect(window.visibleRange(in: ranges) == 80 ..< 100)
        }

        @Test
        func conversationWindowKeepsAnOlderPageStableAsNewMessagesArrive() {
            var window = CodexChatConversationWindow()
            let messages = alternatingMessages(count: 100)
            window.showEarlierMessages(in: CodexChatConversationWindow.pageRanges(in: messages))

            let appendedRanges = CodexChatConversationWindow.pageRanges(in: alternatingMessages(count: 102))
            #expect(window.visibleRange(in: appendedRanges) == 40 ..< 80)
        }

        @Test
        func conversationWindowKeepsAUserAndAssistantOnTheSamePage() {
            let messages = alternatingMessages(count: 82)
            let ranges = CodexChatConversationWindow.pageRanges(in: messages)

            #expect(ranges == [0 ..< 40, 40 ..< 80, 80 ..< 82])
            #expect(ranges.dropLast().allSatisfy { range in
                !(messages[range.upperBound - 1].role == .user
                    && messages[range.upperBound].role == .assistant)
            })
        }

        @Test
        func conversationWindowRoundTripsAnOddLatestPage() {
            var window = CodexChatConversationWindow()
            let messages = alternatingMessages(count: 101)
            let ranges = CodexChatConversationWindow.pageRanges(in: messages)
            let latestRange = window.visibleRange(in: ranges)

            window.showEarlierMessages(in: ranges)
            window.showLaterMessages(in: ranges)

            #expect(window.visibleRange(in: ranges) == latestRange)
        }

        @Test
        func conversationWindowDoesNotSkipMixedRoleMessages() {
            let messages = mixedRoleMessages(count: 118)
            let ranges = CodexChatConversationWindow.pageRanges(in: messages)

            #expect(ranges.flatMap(Array.init) == Array(messages.indices))
            #expect(ranges.allSatisfy { $0.count <= CodexChatConversationWindow.pageSize })
            #expect(ranges.dropLast().allSatisfy { range in
                !(messages[range.upperBound - 1].role == .user
                    && messages[range.upperBound].role == .assistant)
            })
        }

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

        private func alternatingMessages(count: Int) -> [CodexChatMessage] {
            (0..<count).map { index in
                CodexChatMessage(
                    id: "message-\(index)",
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    text: "Message \(index)"
                )
            }
        }

        private func mixedRoleMessages(count: Int) -> [CodexChatMessage] {
            let roles: [CodexChatMessage.Role] = [.user, .assistant, .assistant, .user, .user]
            return (0..<count).map { index in
                CodexChatMessage(
                    id: "message-\(index)",
                    role: roles[index % roles.count],
                    text: "Message \(index)"
                )
            }
        }
    }
#endif
