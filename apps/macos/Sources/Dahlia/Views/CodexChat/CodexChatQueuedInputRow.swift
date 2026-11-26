import SwiftUI

struct CodexChatQueuedInputRow: View {
    @Bindable var session: CodexChatSessionModel
    let input: CodexChatManualSubmission
    @State private var isSendNowHovered = false

    private var isEditing: Bool { session.editingPendingInputID == input.id }

    private var canSave: Bool {
        session.pendingInputEditDraft.nilIfBlank != nil || !session.pendingInputEditImages.isEmpty
            || input.composerSnapshot?.referenceIDs.isEmpty == false
            || input.composerSnapshot?.threadReferenceIDs.isEmpty == false
    }

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 72)
            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    if input.startsFreshSession {
                        Label(L10n.chatNewSession, systemImage: "eraser")
                            .font(.dahliaSecondary)
                            .foregroundStyle(DahliaDesign.secondaryTextColor)
                    }
                    if isEditing {
                        TextField(L10n.messageDahliaAI, text: $session.pendingInputEditDraft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(2 ... 8)
                        if !session.pendingInputEditImages.isEmpty {
                            CodexChatAttachmentStrip(attachments: session.pendingInputEditImages) { id in
                                session.pendingInputEditImages.removeAll { $0.id == id }
                            }
                        }
                    } else {
                        CodexChatUserMessageContent(
                            rawText: input.text,
                            images: input.images,
                            meetingNamesByID: session.meetingNamesByID,
                            meetingReferencesByID: session.meetingReferencesByID
                        )
                        .lineLimit(3)
                    }
                }
                .font(.dahliaBody)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: CodexChatDesign.messageCornerRadius)
                        .strokeBorder(DahliaDesign.secondaryTextColor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }

                HStack(spacing: 2) {
                    if isEditing {
                        Button(L10n.cancel, action: session.cancelEditingPendingInput)
                        Button(L10n.save) {
                            session.savePendingInput(id: input.id, draft: session.pendingInputEditDraft, images: session.pendingInputEditImages)
                        }
                        .disabled(!canSave)
                    } else {
                        Button {
                            session.sendPendingInputNow(id: input.id)
                        } label: {
                            Label(L10n.chatSendNow, systemImage: "arrow.up")
                                .padding(.horizontal, 6)
                                .frame(height: CodexChatDesign.headerControlSize)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            isSendNowHovered && session.canSendPendingInput(input) ? DahliaDesign.contentHighlightColor : .clear,
                            in: RoundedRectangle(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
                        )
                        .onHover { isSendNowHovered = $0 }
                        .disabled(!session.canSendPendingInput(input))
                        CodexChatIconButton(label: L10n.edit, systemImage: "pencil") {
                            session.beginEditingPendingInput(id: input.id)
                        }
                        .disabled(session.editingPendingInputID != nil)
                        CodexChatIconButton(label: L10n.delete, systemImage: "xmark") {
                            session.removePendingInput(id: input.id)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .font(.dahliaSecondary)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
        .padding(.vertical, 6)
    }
}
