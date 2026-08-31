import SwiftUI

struct CodexChatConversationScrollState: Equatable {
    let isAtBottom: Bool

    func updatedFollowState(previous: Bool, isResizing: Bool) -> Bool {
        isResizing ? previous : isAtBottom
    }
}

struct CodexChatConversationStructure: Equatable {
    let conversationID: CodexChatSessionID
    let messageCount: Int
    let firstMessageID: String?
    let lastMessageID: String?
}

struct CodexChatConversationWindow: Equatable {
    static let pageSize = 40

    private var upperBound: Int?

    static func pageRanges(in messages: [CodexChatMessage]) -> [Range<Int>] {
        guard !messages.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var pageStart = 0
        var index = 0

        while index < messages.count {
            let unitSize = if messages[index].role == .user,
                              index + 1 < messages.count,
                              messages[index + 1].role == .assistant {
                2
            } else {
                1
            }
            if index > pageStart, index - pageStart + unitSize > pageSize {
                ranges.append(pageStart ..< index)
                pageStart = index
            }
            index += unitSize
        }

        ranges.append(pageStart ..< messages.count)
        return ranges
    }

    func visibleRange(in ranges: [Range<Int>]) -> Range<Int> {
        guard !ranges.isEmpty else { return 0 ..< 0 }
        return ranges[selectedPageIndex(in: ranges)]
    }

    func hasEarlierMessages(in ranges: [Range<Int>]) -> Bool {
        visibleRange(in: ranges).lowerBound > 0
    }

    func hasLaterMessages(in ranges: [Range<Int>]) -> Bool {
        selectedPageIndex(in: ranges) < ranges.count - 1
    }

    mutating func showEarlierMessages(in ranges: [Range<Int>]) {
        let index = selectedPageIndex(in: ranges)
        guard index > 0 else { return }
        upperBound = ranges[index - 1].upperBound
    }

    mutating func showLaterMessages(in ranges: [Range<Int>]) {
        let nextIndex = selectedPageIndex(in: ranges) + 1
        guard nextIndex < ranges.count else { return }
        upperBound = nextIndex == ranges.count - 1 ? nil : ranges[nextIndex].upperBound
    }

    mutating func showLatestMessages() {
        upperBound = nil
    }

    private func selectedPageIndex(in ranges: [Range<Int>]) -> Int {
        guard let upperBound,
              let index = ranges.firstIndex(where: { $0.upperBound == upperBound })
        else {
            return max(0, ranges.count - 1)
        }
        return index
    }
}

struct CodexChatConversationView: View {
    let conversationID: CodexChatSessionID
    let messages: [CodexChatMessage]
    let showsStandaloneThinking: Bool
    let meetingNamesByID: [UUID: String]
    let meetingReferencesByID: [UUID: CodexChatMeetingReference]

    @Environment(\.isChatSidebarResizing) private var isChatSidebarResizing
    @State private var isFollowingLatest = true
    @State private var conversationWindow = CodexChatConversationWindow()
    @State private var cachedStructure: CodexChatConversationStructure?
    @State private var cachedPageRanges: [Range<Int>] = []

    var body: some View {
        let structure = CodexChatConversationStructure(
            conversationID: conversationID,
            messageCount: messages.count,
            firstMessageID: messages.first?.id,
            lastMessageID: messages.last?.id
        )
        let pageRanges = cachedStructure == structure
            ? cachedPageRanges
            : CodexChatConversationWindow.pageRanges(in: messages)
        let visibleRange = conversationWindow.visibleRange(in: pageRanges)
        let hasEarlierMessages = conversationWindow.hasEarlierMessages(in: pageRanges)
        let hasLaterMessages = conversationWindow.hasLaterMessages(in: pageRanges)
        let previousUserMessage = messages[..<visibleRange.lowerBound].last { $0.role == .user }
        let items = CodexChatConversationItem.build(
            from: Array(messages[visibleRange]),
            showsStandaloneThinking: showsStandaloneThinking && !hasLaterMessages,
            previousUserContext: previousUserMessage?.context,
            hasPreviousUserMessage: previousUserMessage != nil
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if hasEarlierMessages || hasLaterMessages {
                    HStack {
                        if hasEarlierMessages {
                            Button(L10n.chatEarlierMessages, systemImage: "chevron.up") {
                                conversationWindow.showEarlierMessages(in: pageRanges)
                            }
                        }
                        Spacer()
                        if hasLaterMessages {
                            Button(L10n.chatLaterMessages, systemImage: "chevron.down") {
                                conversationWindow.showLaterMessages(in: pageRanges)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                }

                ForEach(items) { item in
                    switch item {
                    case let .contextDivider(_, context):
                        CodexChatContextDivider(context: context)
                    case let .message(message, showsInlineActivity):
                        CodexChatMessageRow(
                            message: message,
                            showsInlineActivity: showsInlineActivity,
                            meetingNamesByID: meetingNamesByID,
                            meetingReferencesByID: meetingReferencesByID
                        )
                    case .thinking:
                        CodexChatThinkingIndicator()
                    }
                }
            }
            .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(isFollowingLatest ? .bottom : nil, for: .sizeChanges)
        .onScrollGeometryChange(for: CodexChatConversationScrollState.self) { geometry in
            let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
            return CodexChatConversationScrollState(
                isAtBottom: visibleBottom >= geometry.contentSize.height - 24
            )
        } action: { _, current in
            isFollowingLatest = current.updatedFollowState(
                previous: isFollowingLatest,
                isResizing: isChatSidebarResizing
            )
        }
        .onChange(of: conversationID) {
            conversationWindow.showLatestMessages()
            isFollowingLatest = true
        }
        .onChange(of: structure, initial: true) { _, current in
            cachedPageRanges = pageRanges
            cachedStructure = current
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
