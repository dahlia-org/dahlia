import SwiftUI

private extension DetailTab {
    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .summary: "1"
        case .notes: "2"
        case .screenshots: "3"
        case .transcript: "4"
        case .conversationAnalytics: "5"
        }
    }
}

/// Navigation for the content that belongs to the selected meeting.
struct DetailTabBar: View {
    @Binding var selection: DetailTab
    @ObservedObject var viewModel: CaptionViewModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionIndicator
    @State private var hoveredTab: DetailTab?

    private var isFolderOnly: Bool {
        viewModel.currentMeetingId == nil && !viewModel.isListening && !viewModel.hasDraftMeeting
    }

    private var availableTabs: [DetailTab] {
        DetailTab.allCases.filter {
            $0 != .conversationAnalytics || settings.isConversationAnalyticsBetaEnabled
        }
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(availableTabs) { tab in
                    let isSelected = tab == selection

                    Button {
                        select(tab)
                    } label: {
                        ZStack {
                            Text(tab.label)
                                .font(.body.weight(.semibold))
                                .hidden()
                            Text(tab.label)
                                .font(isSelected ? .body.weight(.semibold) : .body)
                        }
                        .padding(.horizontal, DahliaDesign.tabHorizontalPadding)
                        .padding(.vertical, DahliaDesign.tabVerticalPadding)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? DahliaDesign.primaryTextColor : DahliaDesign.secondaryTextColor)
                    .background {
                        if !isFolderOnly, hoveredTab == tab {
                            RoundedRectangle(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
                                .fill(DahliaDesign.contentHighlightColor)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if isSelected {
                            Capsule()
                                .fill(.primary)
                                .frame(height: DahliaDesign.tabIndicatorHeight)
                                .padding(.horizontal, 8)
                                .matchedGeometryEffect(id: "detail-tab-selection", in: selectionIndicator)
                        }
                    }
                    .onHover { hovering in
                        guard !isFolderOnly else { return }
                        if hovering {
                            hoveredTab = tab
                        } else if hoveredTab == tab {
                            hoveredTab = nil
                        }
                    }
                    .keyboardShortcut(tab.keyboardShortcut, modifiers: .command)
                    .help(tab.label)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .scrollIndicators(.hidden)
        .disabled(isFolderOnly)
        .onChange(of: isFolderOnly) { _, folderOnly in
            if folderOnly {
                hoveredTab = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.meetingContent)
    }

    private func select(_ tab: DetailTab) {
        guard tab != selection else { return }
        if reduceMotion {
            selection = tab
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                selection = tab
            }
        }
    }
}
