import AppKit
import SwiftUI

struct CodexChatComposer: View {
    @Bindable var session: CodexChatSessionModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(L10n.messageCodex, text: $session.draft, axis: .vertical)
                .font(.body)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 5)
                .padding(.leading, 8)
                .padding(.vertical, 6)
                .contentShape(.rect)
                .onContinuousHover(perform: updateTextInputCursor)
                .accessibilityLabel(L10n.messageCodex)
                .onSubmit(handleSubmit)

            if session.isLoading, session.models.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: CodexChatDesign.controlSize, height: CodexChatDesign.controlSize)
                    .accessibilityLabel(L10n.chatModelLoading)
            } else if !session.models.isEmpty {
                CodexChatConfigurationButton(session: session)
            }

            if session.isGenerating {
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
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: CodexChatDesign.composerCornerRadius)
                .fill(.background)
                .overlay {
                    RoundedRectangle(cornerRadius: CodexChatDesign.composerCornerRadius)
                        .stroke(.separator.opacity(0.55), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.05), radius: 12, y: 3)
    }

    private func handleSubmit() {
        guard NSApp.currentEvent?.modifierFlags.contains(.shift) == true else {
            session.sendDraft()
            return
        }

        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            session.draft.append("\n")
            return
        }

        textView.insertNewlineIgnoringFieldEditor(nil)
    }

    private func updateTextInputCursor(_ phase: HoverPhase) {
        switch phase {
        case .active:
            NSCursor.iBeam.set()
        case .ended:
            NSCursor.arrow.set()
        }
    }
}
