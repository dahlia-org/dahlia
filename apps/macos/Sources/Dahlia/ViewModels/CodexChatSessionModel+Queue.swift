import Foundation

extension CodexChatSessionModel {
    func resumeQueue() {
        guard isBoundToCurrentAccount, !isReleased, errorMessage == nil else { return }
        isQueuePaused = false
        processPendingInputIfPossible()
    }

    func canSendPendingInput(_ input: CodexChatManualSubmission) -> Bool {
        isBoundToCurrentAccount && !isReleased && !isRestoring && !needsRestore
            && errorMessage == nil && editingPendingInputID == nil && !isTurnCleanupPending
            && (!isGenerating || !isPreparingTurn && !input.text.hasPrefix("/"))
            && (input.images.isEmpty || selectedModelSupportsImages)
    }

    func sendPendingInputNow(id: UUID) {
        guard let index = pendingManualInputs.firstIndex(where: { $0.id == id }),
              canSendPendingInput(pendingManualInputs[index]) else { return }
        var input = pendingManualInputs.remove(at: index)
        input.deliveryMode = .steer
        pendingManualInputs.insert(input, at: 0)
        resumeQueue()
    }

    func removePendingInput(id: UUID) {
        pendingManualInputs.removeAll { $0.id == id }
        if editingPendingInputID == id { clearPendingInputEdit() }
        processPendingInputIfPossible()
        notifyGenerationCompletionIfIdle()
    }

    func beginEditingPendingInput(id: UUID) {
        guard editingPendingInputID == nil,
              let input = pendingManualInputs.first(where: { $0.id == id }) else { return }
        pendingInputEditDraft = input.composerSnapshot?.draft ?? input.text
        pendingInputEditImages = input.images
        editingPendingInputID = id
    }

    func cancelEditingPendingInput() {
        clearPendingInputEdit()
        processPendingInputIfPossible()
    }

    private func clearPendingInputEdit() {
        editingPendingInputID = nil
        pendingInputEditDraft = ""
        pendingInputEditImages = []
    }

    func savePendingInput(id: UUID, draft: String, images: [CodexChatImageAttachment]) {
        guard editingPendingInputID == id,
              let index = pendingManualInputs.firstIndex(where: { $0.id == id }) else { return }
        let previous = pendingManualInputs[index]
        let snapshot = CodexChatComposerSnapshot(
            draft: draft,
            referenceIDs: previous.composerSnapshot?.referenceIDs ?? [],
            images: images,
            threadReferences: previous.composerSnapshot?.threadReferences ?? []
        )
        let text = CodexChatMeetingReference.serializedText(referenceIDs: snapshot.referenceIDs, draft: draft)
        let references = snapshot.threadReferenceIDs.map { "thread:" + $0 }.joined(separator: " ")
        let blocks = draft.hasPrefix("/") ? [text, references] : [references, text]
        let serialized = blocks.filter { !$0.isEmpty }.joined(separator: " ")
        guard serialized.nilIfBlank != nil || !images.isEmpty else { return }
        pendingManualInputs[index] = CodexChatManualSubmission(
            id: id,
            deliveryMode: previous.deliveryMode,
            text: serialized,
            images: images,
            composerSnapshot: snapshot,
            includesCurrentContext: !draft.hasPrefix("/")
        )
        pendingManualInputs[index].clearsComposerOnDelivery = false
        cancelEditingPendingInput()
    }
}
