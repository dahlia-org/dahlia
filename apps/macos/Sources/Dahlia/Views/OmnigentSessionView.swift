import AppKit
import SwiftUI

/// An Omnigent session's conversation in the main area, read-only and kept current over SSE.
struct OmnigentSessionView: View {
    let headerLeadingInset: CGFloat
    @State private var model: OmnigentSessionModel

    init(connectionID: UUID, sessionID: String, headerLeadingInset: CGFloat) {
        self.headerLeadingInset = headerLeadingInset
        _model = State(initialValue: OmnigentSessionModel(connectionID: connectionID, sessionID: sessionID))
    }

    var body: some View {
        VStack(spacing: 0) {
            DahliaWindowHeader {
                if headerLeadingInset > 0 {
                    Color.clear
                        .frame(width: headerLeadingInset - DahliaDesign.windowHeaderGroupSpacing)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 8) {
                    OmnigentLogo()
                    Text(L10n.omnigent).fixedSize()
                    Text("/").foregroundStyle(DahliaDesign.secondaryTextColor).accessibilityHidden(true)
                    Text(model.title?.nilIfBlank ?? model.sessionID)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                .font(.dahliaBody)
                .foregroundStyle(DahliaDesign.primaryTextColor)

                Spacer(minLength: 8)

                if let webURL = model.webURL {
                    DahliaWindowHeaderIconButton(label: L10n.omnigentOpenInBrowser, systemImage: "safari") {
                        NSWorkspace.shared.open(webURL)
                    }
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.messages) { message in
                        row(id: message.id, role: message.role, text: message.text, isStreaming: false)
                    }
                    if !model.streamingText.isEmpty {
                        row(id: "streaming", role: "assistant", text: model.streamingText, isStreaming: true)
                    } else if model.isRunning {
                        ProgressView().controlSize(.small).accessibilityLabel(L10n.chatThreadRunning)
                    }
                    statusRow
                }
                .frame(maxWidth: DahliaDesign.mainContentMaxWidth)
                .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
        }
        .task { await model.follow() }
    }

    private func row(id: String, role: String, text: String, isStreaming: Bool) -> some View {
        CodexChatMessageRow(
            message: CodexChatMessage(id: id, role: role == "user" ? .user : .assistant, text: text, isStreaming: isStreaming),
            showsInlineActivity: false,
            meetingNamesByID: [:],
            meetingReferencesByID: [:]
        )
    }

    @ViewBuilder
    private var statusRow: some View {
        if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        } else if !model.isLoaded {
            ProgressView().controlSize(.small)
        } else if model.messages.isEmpty, model.streamingText.isEmpty {
            Text(L10n.omnigentNoMessages).foregroundStyle(DahliaDesign.secondaryTextColor)
        }
        if model.status == "failed" {
            Label(L10n.chatRunStatus("failed"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}

/// Omnigent's starfish mark, at the size of the text beside it.
struct OmnigentLogo: View {
    static let image = Bundle.appModule.image(forResource: "IntegrationOmnigent").map { Image(nsImage: $0) }

    var body: some View {
        if let image = Self.image {
            image
                .resizable()
                .scaledToFit()
                .frame(width: DahliaTypography.size(), height: DahliaTypography.size())
                .accessibilityHidden(true)
        }
    }
}
