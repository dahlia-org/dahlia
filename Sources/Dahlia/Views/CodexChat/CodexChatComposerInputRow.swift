import SwiftUI

struct CodexChatComposerInputRow: View {
    @Bindable var session: CodexChatSessionModel
    let showsAddPanel: Bool
    let showsMeetingPicker: Bool
    let suggestions: [CodexChatMeetingReference]
    let highlightedMeetingID: UUID?
    let onShowImageImporter: () -> Void
    let onToggleAddPanel: () -> Void
    let onShowMeetingPicker: () -> Void
    let onSelectMeeting: (CodexChatMeetingReference) -> Void
    let onPasteImages: () -> Bool
    let onSubmit: () -> Void
    let onMoveCommand: (MoveCommandDirection) -> Void
    let onExitCommand: () -> Void
    let onHover: (HoverPhase) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button(L10n.addToChat, systemImage: "plus", action: onToggleAddPanel)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: CodexChatDesign.controlSize, height: CodexChatDesign.controlSize)
                .background(.quaternary, in: Circle())
                .contentShape(Circle())
                .help(L10n.addToChat)
                .overlay(alignment: .bottomLeading) {
                    if showsAddPanel {
                        CodexChatAddPanel(
                            showsMeetingPicker: showsMeetingPicker,
                            meetingReferences: suggestions,
                            highlightedMeetingID: highlightedMeetingID,
                            onAttachImages: onShowImageImporter,
                            onAddMeetingReference: onShowMeetingPicker,
                            onSelectMeeting: onSelectMeeting
                        )
                        .offset(y: -(CodexChatDesign.controlSize + 8))
                        .zIndex(1)
                    }
                }
                .onExitCommand(perform: onExitCommand)
                .zIndex(showsAddPanel ? 1 : 0)

            TextField(L10n.messageCodex, text: $session.draft, axis: .vertical)
                .font(.body)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 5)
                .padding(.leading, 8)
                .padding(.vertical, 6)
                .contentShape(.rect)
                .onContinuousHover(perform: onHover)
                .accessibilityLabel(L10n.messageCodex)
                .onSubmit(onSubmit)
                .onMoveCommand(perform: onMoveCommand)
                .onExitCommand(perform: onExitCommand)
                .onKeyPress("v", phases: .down) { keyPress in
                    guard keyPress.modifiers.contains(.command), onPasteImages() else { return .ignored }
                    return .handled
                }

            if session.isLoading, session.models.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: CodexChatDesign.controlSize, height: CodexChatDesign.controlSize)
                    .accessibilityLabel(L10n.chatModelLoading)
            } else if !session.models.isEmpty {
                CodexChatConfigurationButton(session: session)
            }

            if session.isGenerating, !session.canSend {
                CodexChatActionButton(
                    label: L10n.stopGenerating,
                    systemImage: "stop.fill",
                    isEnabled: true,
                    action: session.stop
                )
            } else {
                CodexChatActionButton(
                    label: L10n.sendMessage,
                    systemImage: "arrow.up",
                    isEnabled: session.canSend,
                    action: session.sendDraft
                )
            }
        }
    }
}
