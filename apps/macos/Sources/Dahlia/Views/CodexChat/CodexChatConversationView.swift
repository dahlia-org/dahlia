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

    mutating func showEarliestMessages() {
        upperBound = 0
    }

    private func selectedPageIndex(in ranges: [Range<Int>]) -> Int {
        if upperBound == 0 { return 0 }
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
    let contentMaxWidth: CGFloat?
    let hasStoredEarlierMessages: Bool
    let isLoadingEarlierMessages: Bool
    let canLoadEarlierMessages: Bool
    let onLoadEarlierMessages: () async -> Void
    let parentThreadID: String?
    let currentRunID: UUID?
    @Bindable var coordinator: CodexChatCoordinator
    let onOpenThread: (CodexChatThreadSummary) -> Void

    @Environment(\.isChatSidebarResizing) private var isChatSidebarResizing
    @State private var isFollowingLatest = true
    @State private var conversationWindow = CodexChatConversationWindow()
    @State private var cachedStructure: CodexChatConversationStructure?
    @State private var cachedPageRanges: [Range<Int>] = []
    @State private var earlierMessagesTask: Task<Void, Never>?
    @State private var relatedThreads: [CodexChatThreadSummary] = []
    @State private var relatedThreadsError: String?
    @State private var relatedThreadAnchors: [String: [CodexChatThreadSummary]] = [:]

    private var relatedThreadsRevision: String {
        (parentThreadID ?? "") + coordinator.runtimeStates.map {
            "\($0.threadID):\($0.turnID):\($0.status):\($0.approvals.map(\.id).joined())"
        }.sorted().joined(separator: ",")
    }

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
            hasPreviousUserMessage: previousUserMessage != nil,
            relatedThreadsByMessageID: relatedThreadAnchors
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if hasEarlierMessages || hasLaterMessages || hasStoredEarlierMessages {
                    HStack {
                        if hasEarlierMessages {
                            Button(L10n.chatEarlierMessages, systemImage: "chevron.up") {
                                conversationWindow.showEarlierMessages(in: pageRanges)
                            }
                        } else if hasStoredEarlierMessages {
                            Button(L10n.chatEarlierMessages, systemImage: "chevron.up") {
                                earlierMessagesTask = Task {
                                    await onLoadEarlierMessages()
                                    guard !Task.isCancelled else { return }
                                    conversationWindow.showEarliestMessages()
                                }
                            }
                            .disabled(isLoadingEarlierMessages || !canLoadEarlierMessages)
                            if isLoadingEarlierMessages { ProgressView().controlSize(.small) }
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
                        if message.threadResults.isEmpty {
                            CodexChatMessageRow(
                                message: message,
                                showsInlineActivity: showsInlineActivity,
                                meetingNamesByID: meetingNamesByID,
                                meetingReferencesByID: meetingReferencesByID
                            )
                        } else {
                            VStack(spacing: 4) {
                                ForEach(message.threadResults) { result in
                                    CodexChatRelatedThreadRow(
                                        thread: result.thread, meetingNamesByID: meetingNamesByID,
                                        onOpen: { onOpenThread(result.thread) }, isNotification: true
                                    )
                                }
                            }
                        }
                    case .thinking:
                        CodexChatThinkingIndicator()
                    case let .relatedThreads(_, threads):
                        CodexChatRelatedThreadsView(threads: threads, coordinator: coordinator, onOpen: onOpenThread)
                    }
                }
                if let relatedThreadsError {
                    Text(relatedThreadsError).font(.dahliaSecondary).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
            .padding(.vertical, 12)
            .frame(maxWidth: contentMaxWidth ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity)
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
            earlierMessagesTask?.cancel()
            conversationWindow.showLatestMessages()
            isFollowingLatest = true
            relatedThreads = []
            relatedThreadsError = nil
            relatedThreadAnchors = [:]
        }
        .task(id: relatedThreadsRevision) {
            guard let parentThreadID else {
                relatedThreads = []
                relatedThreadsError = nil
                return
            }
            do {
                let loaded = try await coordinator.relatedThreads(parentID: parentThreadID)
                try Task.checkCancellation()
                relatedThreads = loaded
                relatedThreadsError = nil
            } catch is CancellationError {
                // Discard stale reads when changing conversations.
            } catch { relatedThreadsError = error.localizedDescription }
        }
        .onDisappear { earlierMessagesTask?.cancel() }
        .onChange(of: structure, initial: true) { _, current in
            cachedPageRanges = pageRanges
            cachedStructure = current
            updateRelatedThreadAnchors()
        }
        .onChange(of: relatedThreads) { updateRelatedThreadAnchors() }
        .onChange(of: currentRunID) { updateRelatedThreadAnchors() }
        .onChange(of: messages.last?.hasResponseContent) { updateRelatedThreadAnchors() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updateRelatedThreadAnchors() {
        relatedThreadAnchors = CodexChatConversationItem.relatedThreadAnchors(
            threads: relatedThreads, messages: messages, currentRunID: currentRunID
        )
    }
}
