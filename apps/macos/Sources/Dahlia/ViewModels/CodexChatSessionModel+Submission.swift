import Foundation

extension CodexChatSessionModel {
    func acceptedImageCandidates<Item>(from items: [Item]) -> [Item] {
        let availableSlots = max(
            0,
            Self.maximumAttachedImages - attachedImages.count - pendingImagePreparationCount
        )
        let acceptedItems = Array(items.prefix(availableSlots))
        if acceptedItems.count < items.count {
            noticeMessage = L10n.chatImageLimitReached(Self.maximumAttachedImages)
        }
        return acceptedItems
    }

    func makeAppServerInputs(
        text: String?,
        context: CodexChatContext?,
        images: [CodexChatImageAttachment]
    ) -> [CodexAppServerInput] {
        let textInputs = CodexChatPromptCodec.encodeTextBlocks(text: text ?? "", context: context).map(CodexAppServerInput.text)
        return textInputs + images.map { .imageDataURI($0.dataURI) }
    }

    func submit(
        _ text: String,
        images: [CodexChatImageAttachment] = [],
        composerSnapshot: CodexChatComposerSnapshot? = nil,
        includesCurrentContext: Bool = true,
        startsFreshSession freshSession: Bool? = nil,
        queuedSubmission: CodexChatManualSubmission? = nil
    ) {
        guard isBoundToCurrentAccount,
              !isRestoring,
              !needsRestore,
              !isGenerating,
              !isTurnCleanupPending,
              text.nilIfBlank != nil || !images.isEmpty else { return }
        if let message = compactImageValidationMessage(text: text, hasImages: !images.isEmpty) {
            noticeMessage = message
            return
        }
        guard images.isEmpty || models.isEmpty || selectedModelSupportsImages else {
            noticeMessage = L10n.chatModelDoesNotSupportImages
            return
        }
        prepareFailureStateForSubmission()
        let input = queuedSubmission ?? CodexChatManualSubmission(
            startsFreshSession: freshSession ?? startsFreshSession, text: text, images: images,
            composerSnapshot: composerSnapshot, includesCurrentContext: includesCurrentContext
        )
        preparingSubmission = (input: input, fromQueue: queuedSubmission != nil)
        isGenerating = true
        isPreparingTurn = true
        isAwaitingTurnOutput = false
        preparingManualComposerSnapshot = composerSnapshot
        preparingUserMessage = CodexChatMessage(role: .user, text: text, images: images, timestamp: .now)
        preparingUserMessage?.startsFreshSession = input.startsFreshSession
        if freshSession == nil { startsFreshSession = false }
        clearComposer(ifMatching: composerSnapshot)
        errorMessage = nil
        let submissionID = UUID.v7()
        activeSubmissionID = submissionID
        let approvalMethod = selectedApprovalMethod

        turnTask = Task { [weak self] in
            await self?.resolveContextAndRunTurn(
                text: text,
                images: images,
                includesCurrentContext: includesCurrentContext,
                approvalMethod: approvalMethod,
                submissionID: submissionID
            )
        }
    }

    func submitManualSubmission(_ submission: CodexChatManualSubmission, fromQueue: Bool = false) {
        submit(
            submission.text,
            images: submission.images,
            composerSnapshot: submission.clearsComposerOnDelivery ? submission.composerSnapshot : nil,
            includesCurrentContext: submission.includesCurrentContext,
            startsFreshSession: submission.startsFreshSession,
            queuedSubmission: fromQueue ? submission : nil
        )

    }

    func resolveContextAndRunTurn(
        text: String,
        images: [CodexChatImageAttachment],
        includesCurrentContext: Bool,
        approvalMethod: CodexChatApprovalMethod,
        submissionID: UUID
    ) async {
        defer {
            finishGeneration(submissionID: submissionID)
        }
        let context: CodexChatContext?
        do {
            context = try await resolveContext(if: includesCurrentContext)
            try ensureSubmissionCanContinue(submissionID)
        } catch is CancellationError {
            return
        } catch {
            guard activeSubmissionID == submissionID else { return }
            recordFailedSubmission(
                text: text,
                images: images,
                includesCurrentContext: includesCurrentContext
            )
            errorMessage = error.localizedDescription
            return
        }
        guard !isReleased, isBoundToCurrentAccount else { return }
        preparingUserMessage?.context = context
        let responseID = "pending-\(UUID.v7().uuidString)"

        _ = await runTurn(
            text: text,
            images: images,
            context: context,
            includesCurrentContext: includesCurrentContext,
            responseID: responseID,
            approvalMethod: approvalMethod,
            submissionID: submissionID
        )
    }

    func enqueueManualInput(_ submission: CodexChatManualSubmission) {
        lastSubmittedText = submission.text
        lastManualSubmission = submission
        var queued = submission
        if submission.deliveryMode == .queue || submission.text.hasPrefix("/") || submission.startsFreshSession {
            clearComposer(ifMatching: submission.composerSnapshot)
            queued.clearsComposerOnDelivery = false
        }
        pendingManualInputs.append(queued)
        processPendingInputIfPossible()
    }

    var serializedComposerText: String {
        let text = CodexChatMeetingReference.serializedText(referenceIDs: selectedMeetingReferenceIDs, draft: draft)
        let references = selectedThreadReferences.map { "thread:" + $0.id }.joined(separator: " ")
        guard !references.isEmpty else { return text }
        return draft.hasPrefix("/") ? [text, references].joined(separator: " ") : [references, text].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func clearComposer(ifMatching snapshot: CodexChatComposerSnapshot?) {
        guard let snapshot else { return }
        if draft == snapshot.draft {
            draft = ""
        }
        if selectedMeetingReferenceIDs == snapshot.referenceIDs {
            selectedMeetingReferenceIDs = []
        }
        if selectedThreadReferences.map(\.id) == snapshot.threadReferenceIDs {
            selectedThreadReferences = []
        }
        if attachedImages == snapshot.images {
            attachedImages = []
        }
    }

    func retryManualSubmission(_ submission: CodexChatManualSubmission) {
        let currentText = serializedComposerText
        let composerSnapshot: CodexChatComposerSnapshot? = if currentText == submission.text,
                                                              attachedImages == submission.images {
            CodexChatComposerSnapshot(
                draft: draft,
                referenceIDs: selectedMeetingReferenceIDs,
                images: attachedImages,
                threadReferences: selectedThreadReferences
            )
        } else {
            nil
        }
        submitManualSubmission(CodexChatManualSubmission(
            startsFreshSession: submission.startsFreshSession,
            text: submission.text,
            images: submission.images,
            composerSnapshot: composerSnapshot,
            includesCurrentContext: submission.includesCurrentContext
        ))
    }

    func resolveContext(if isRequired: Bool) async throws -> CodexChatContext? {
        guard isRequired else { return nil }
        if backendThreadID == nil, hasSelectedProject { return try selectedScopeContext() }
        guard let workspaceID = contextWorkspaceID else { return nil }
        return try await contextProvider.currentContext(workspaceID: workspaceID)
    }

    func compactImageValidationMessage(text: String, hasImages: Bool) -> String? {
        guard hasImages, PiChatService.compactInstructions([.text(text)]) != nil else { return nil }
        return L10n.chatCompactDoesNotSupportImages
    }

    static let maximumAttachedImages = CodexChatImageAttachment.maximumAttachmentCount
}
