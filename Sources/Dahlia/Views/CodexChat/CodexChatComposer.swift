import AppKit
import SwiftUI

struct CodexChatComposer: View {
    @Bindable var session: CodexChatSessionModel
    @State private var isMeetingPickerPresented = false
    @State private var meetingQuery = ""
    @State private var highlightedMeetingID: UUID?
    @State private var suggestions: [CodexChatMeetingReference] = []
    @State private var consumesTrailingMentionOnSelection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !session.selectedMeetingReferenceIDs.isEmpty {
                CodexChatMeetingReferenceBar(
                    referenceIDs: session.selectedMeetingReferenceIDs,
                    referencesByID: session.meetingReferencesByID,
                    onRemove: session.removeMeetingReference
                )
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button(L10n.addMeetingReference, systemImage: "plus", action: showMeetingPicker)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(width: CodexChatDesign.controlSize, height: CodexChatDesign.controlSize)
                    .background(.quaternary, in: Circle())
                    .contentShape(Circle())
                    .help(L10n.addMeetingReference)
                    .popover(isPresented: $isMeetingPickerPresented, arrowEdge: .bottom) {
                        CodexChatMeetingPicker(
                            references: suggestions,
                            highlightedID: highlightedMeetingID,
                            onSelect: selectMeeting
                        )
                    }

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
                    .onMoveCommand(perform: handleMoveCommand)
                    .onExitCommand(perform: closeMeetingPicker)

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
        .onChange(of: session.draft, handleDraftChange)
        .onChange(of: session.availableMeetingReferences) {
            refreshSuggestionsIfPresented()
        }
        .onChange(of: session.selectedMeetingReferenceIDs) {
            refreshSuggestionsIfPresented()
        }
    }

    private func handleSubmit() {
        if isMeetingPickerPresented,
           let highlightedMeetingID,
           let reference = suggestions.first(where: { $0.id == highlightedMeetingID }) {
            selectMeeting(reference)
            return
        }
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

    private func handleDraftChange(_: String, _ newValue: String) {
        guard let query = CodexChatMeetingReference.trailingMentionQuery(in: newValue) else {
            if isMeetingPickerPresented {
                closeMeetingPicker()
            }
            return
        }
        meetingQuery = query
        consumesTrailingMentionOnSelection = true
        isMeetingPickerPresented = true
        refreshSuggestions()
    }

    private func showMeetingPicker() {
        meetingQuery = ""
        consumesTrailingMentionOnSelection = false
        isMeetingPickerPresented = true
        refreshSuggestions()
    }

    private func closeMeetingPicker() {
        isMeetingPickerPresented = false
        meetingQuery = ""
        highlightedMeetingID = nil
        consumesTrailingMentionOnSelection = false
    }

    private func selectMeeting(_ reference: CodexChatMeetingReference) {
        session.draft = CodexChatMeetingReference.draftAfterSelectingReference(
            session.draft,
            consumesTrailingMention: consumesTrailingMentionOnSelection
        )
        session.addMeetingReference(reference)
        closeMeetingPicker()
    }

    private func refreshSuggestionsIfPresented() {
        guard isMeetingPickerPresented else { return }
        refreshSuggestions()
    }

    private func refreshSuggestions() {
        suggestions = CodexChatMeetingReference.suggestions(
            from: session.availableMeetingReferences,
            excluding: session.selectedMeetingReferenceIDs,
            query: meetingQuery
        )
        updateHighlightedMeeting()
    }

    private func updateHighlightedMeeting() {
        guard !suggestions.contains(where: { $0.id == highlightedMeetingID }) else { return }
        highlightedMeetingID = suggestions.first?.id
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        guard isMeetingPickerPresented, !suggestions.isEmpty else { return }
        switch direction {
        case .up:
            highlightedMeetingID = CodexChatMeetingPickerSelection.moving(
                currentID: highlightedMeetingID,
                in: suggestions,
                by: -1
            )
        case .down:
            highlightedMeetingID = CodexChatMeetingPickerSelection.moving(
                currentID: highlightedMeetingID,
                in: suggestions,
                by: 1
            )
        default:
            return
        }
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
