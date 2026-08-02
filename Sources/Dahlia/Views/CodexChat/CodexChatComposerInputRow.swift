import AppKit
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
            Button(action: onToggleAddPanel) {
                Label(L10n.addToChat, systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .frame(width: CodexChatDesign.controlSize, height: CodexChatDesign.controlSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(.quaternary, in: Circle())
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
                    .codexChatDismissOnOutsideClick(perform: onExitCommand)
                    .offset(y: -(CodexChatDesign.controlSize + 8))
                    .zIndex(1)
                }
            }
            .onExitCommand(perform: onExitCommand)
            .zIndex(showsAddPanel ? 1 : 0)

            CodexChatComposerTextEditor(
                text: $session.draft,
                onSubmit: onSubmit,
                onMoveCommand: onMoveCommand,
                onExitCommand: onExitCommand,
                onPasteImages: onPasteImages,
                onHover: onHover
            )

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

struct CodexChatComposerTextEditor: View {
    @Binding var text: String
    let onSubmit: () -> Void
    let onMoveCommand: (MoveCommandDirection) -> Void
    let onExitCommand: () -> Void
    let onPasteImages: () -> Bool
    let onHover: (HoverPhase) -> Void

    private static let maximumLineCount = 5

    var body: some View {
        // The capped Text supplies intrinsic height while TextEditor owns native scrolling.
        Text(text.isEmpty ? " " : text)
            .font(.body)
            .lineLimit(Self.maximumLineCount)
            .padding(.leading, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            .hidden()
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.leading, 3)
                        .padding(.vertical, 6)
                        .accessibilityLabel(L10n.messageCodex)
                        .onMoveCommand(perform: onMoveCommand)
                        .onExitCommand(perform: onExitCommand)
                        .onKeyPress(.return, phases: .down, action: handleReturnKey)
                        .onKeyPress(.tab, phases: .down, action: handleTabKey)
                        .onKeyPress("v", phases: .down) { keyPress in
                            guard keyPress.modifiers.contains(.command), onPasteImages() else { return .ignored }
                            return .handled
                        }

                    if text.isEmpty {
                        Text(L10n.messageCodex)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 8)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
                .onContinuousHover(perform: onHover)
            }
    }

    private func handleReturnKey(_ keyPress: KeyPress) -> KeyPress.Result {
        if keyPress.modifiers.contains(.shift) {
            return .ignored
        }
        if activeTextView?.hasMarkedText() == true {
            return .ignored
        }
        onSubmit()
        return .handled
    }

    private func handleTabKey(_ keyPress: KeyPress) -> KeyPress.Result {
        guard !keyPress.modifiers.contains(.option),
              !keyPress.modifiers.contains(.command),
              !keyPress.modifiers.contains(.control)
        else {
            return .ignored
        }

        let textView = activeTextView
        if textView?.hasMarkedText() == true {
            return .ignored
        }
        if let textView, let window = textView.window {
            if keyPress.modifiers.contains(.shift) {
                window.selectPreviousKeyView(textView)
            } else {
                window.selectNextKeyView(textView)
            }
        }
        return .handled
    }

    private var activeTextView: NSTextView? {
        let window = NSApp.currentEvent?.window ?? NSApp.keyWindow
        return window?.firstResponder as? NSTextView
    }
}
