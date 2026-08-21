import AppKit
import SwiftUI

struct CodexChatComposerInputRow: View {
    @Bindable var session: CodexChatSessionModel
    let configurationPresentation: Binding<Bool>?
    @FocusState.Binding var isComposerFocused: Bool
    let onToggleAddPanel: () -> Void
    let onPasteImages: () -> Bool
    let onSubmit: () -> Void
    let onMoveCommand: (MoveCommandDirection) -> Void
    let onExitCommand: () -> Void
    let onHover: (HoverPhase) -> Void

    @State private var isAddButtonHovered = false

    var body: some View {
        VStack(spacing: 0) {
            CodexChatComposerTextEditor(
                text: $session.draft,
                isFocused: $isComposerFocused,
                onSubmit: onSubmit,
                onMoveCommand: onMoveCommand,
                onExitCommand: onExitCommand,
                onPasteImages: onPasteImages,
                onHover: onHover
            )

            controlBar
        }
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            Button(action: onToggleAddPanel) {
                Label(L10n.addToChat, systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .dahliaFixedSymbol()
                    .frame(width: CodexChatDesign.controlSize, height: CodexChatDesign.controlSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DahliaDesign.secondaryTextColor)
            .background(isAddButtonHovered ? DahliaDesign.contentHighlightColor : .clear, in: Circle())
            .onHover { isAddButtonHovered = $0 }
            .dahliaHoverHelp(label: L10n.addToChat, shortcut: "@")
            .onExitCommand(perform: onExitCommand)

            CodexChatApprovalMethodButton(session: session)

            Spacer(minLength: 0)

            if session.isLoading, session.models.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: CodexChatDesign.controlSize, height: CodexChatDesign.controlSize)
                    .accessibilityLabel(L10n.chatModelLoading)
            } else if !session.models.isEmpty {
                CodexChatConfigurationButton(
                    session: session,
                    externalPresentation: configurationPresentation
                )
            }

            if session.isGenerating, session.isPreparingTurn || !session.canSend {
                CodexChatActionButton(
                    label: L10n.stopGenerating,
                    systemImage: "stop.fill",
                    isEnabled: true,
                    action: session.stop
                )
            } else if !session.liveModeEnabled, !session.hasComposerContent {
                CodexChatLiveModeStartButton(
                    isEnabled: session.isBoundToCurrentVault && !session.isRestoring && !session.needsRestore,
                    action: session.toggleLiveMode
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
    @FocusState.Binding var isFocused: Bool
    let onSubmit: () -> Void
    let onMoveCommand: (MoveCommandDirection) -> Void
    let onExitCommand: () -> Void
    let onPasteImages: () -> Bool
    let onHover: (HoverPhase) -> Void

    private static let maximumLineCount = 13

    var body: some View {
        // The capped text supplies intrinsic height while the two-line reference sets the minimum.
        ZStack(alignment: .topLeading) {
            Text(text.isEmpty ? " " : text)
                .lineLimit(Self.maximumLineCount)
            Text(verbatim: " \n ")
        }
        .font(.body)
        .padding(.leading, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
        .hidden()
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .focused($isFocused)
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

                if Self.shouldShowPlaceholder(text: text, isFocused: isFocused) {
                    Text(L10n.messageCodex)
                        .font(.body)
                        .foregroundStyle(DahliaDesign.optionalTextColor)
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

    static func shouldShowPlaceholder(text: String, isFocused: Bool) -> Bool {
        text.isEmpty && !isFocused
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
