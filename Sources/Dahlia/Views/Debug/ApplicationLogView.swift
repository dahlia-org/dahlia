import SwiftUI

struct ApplicationLogView: View {
    @State private var model = ApplicationLogViewModel()
    @State private var searchText = ""
    @State private var scrollPosition = ScrollPosition()
    @State private var isFollowingLatest = true

    private var displayedText: String {
        model.text(matching: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = model.errorMessage, model.hasLogs {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                Divider()
            }

            if let errorMessage = model.errorMessage, !model.hasLogs {
                ContentUnavailableView(
                    L10n.applicationLogsUnavailable,
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if !model.hasLogs {
                ContentUnavailableView(
                    L10n.noApplicationLogs,
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(L10n.noApplicationLogsDescription)
                )
            } else if displayedText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(displayedText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding()
                }
                .scrollPosition($scrollPosition)
                .defaultScrollAnchor(.bottomLeading, for: .initialOffset)
                .defaultScrollAnchor(.bottomLeading, for: .alignment)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                    return visibleBottom >= geometry.contentSize.height - 24
                } action: { _, isAtBottom in
                    isFollowingLatest = isAtBottom
                }
            }
        }
        .searchable(text: $searchText, prompt: L10n.searchApplicationLogs)
        .toolbar {
            ToolbarItemGroup {
                Button(
                    L10n.refreshApplicationLogs,
                    systemImage: "arrow.clockwise",
                    action: refreshLogs
                )

                Button(
                    L10n.followLatestApplicationLogs,
                    systemImage: "arrow.down.to.line",
                    action: followLatest
                )
                .disabled(isFollowingLatest || displayedText.isEmpty)

                Button(
                    L10n.copyDisplayedLogs,
                    systemImage: "doc.on.doc",
                    action: copyDisplayedLogs
                )
                .disabled(displayedText.isEmpty)
            }
        }
        .task {
            await model.monitor()
        }
        .onChange(of: model.revision) {
            guard isFollowingLatest else { return }
            scrollToLatest()
        }
        .onChange(of: searchText) {
            guard isFollowingLatest else { return }
            scrollToLatest()
        }
    }

    private func refreshLogs() {
        Task {
            await model.refresh()
        }
    }

    private func followLatest() {
        isFollowingLatest = true
        scrollToLatest()
    }

    private func scrollToLatest() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    private func copyDisplayedLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(displayedText, forType: .string)
    }
}
