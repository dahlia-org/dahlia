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
        includesCurrentContext: Bool = true
    ) {
        guard isBoundToCurrentWorkspace,
              !isRestoring,
              !needsRestore,
              !isGenerating,
              !isTurnCleanupPending,
              text.nilIfBlank != nil || !images.isEmpty else { return }
        guard images.isEmpty || models.isEmpty || selectedModelSupportsImages else {
            noticeMessage = L10n.chatModelDoesNotSupportImages
            return
        }
        prepareFailureStateForSubmission()
        isGenerating = true
        isPreparingTurn = true
        isAwaitingTurnOutput = false
        preparingManualComposerSnapshot = composerSnapshot
        errorMessage = nil
        let submissionID = UUID.v7()
        activeSubmissionID = submissionID
        let approvalMethod = selectedApprovalMethod

        turnTask = Task { [weak self] in
            await self?.resolveContextAndRunTurn(
                text: text,
                images: images,
                composerSnapshot: composerSnapshot,
                includesCurrentContext: includesCurrentContext,
                approvalMethod: approvalMethod,
                submissionID: submissionID
            )
        }
    }

    func submitManualSubmission(_ submission: CodexChatManualSubmission) {
        submit(
            submission.text,
            images: submission.images,
            composerSnapshot: submission.composerSnapshot,
            includesCurrentContext: submission.includesCurrentContext
        )

    }

    func resolveContextAndRunTurn(
        text: String,
        images: [CodexChatImageAttachment],
        composerSnapshot: CodexChatComposerSnapshot?,
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
        guard !isReleased, isBoundToCurrentWorkspace else { return }
        let responseID = "pending-\(UUID.v7().uuidString)"

        _ = await runTurn(
            text: text,
            images: images,
            composerSnapshot: composerSnapshot,
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
        pendingManualInputs.append(submission)
        processPendingInputIfPossible()
    }

    func clearComposer(ifMatching snapshot: CodexChatComposerSnapshot?) {
        guard let snapshot else { return }
        if draft == snapshot.draft {
            draft = ""
        }
        if selectedMeetingReferenceIDs == snapshot.referenceIDs {
            selectedMeetingReferenceIDs = []
        }
        if attachedImages == snapshot.images {
            attachedImages = []
        }
    }

    func retryManualSubmission(_ submission: CodexChatManualSubmission) {
        let currentText = CodexChatMeetingReference.serializedText(
            referenceIDs: selectedMeetingReferenceIDs,
            draft: draft
        )
        let composerSnapshot: CodexChatComposerSnapshot? = if currentText == submission.text,
                                                              attachedImages == submission.images {
            CodexChatComposerSnapshot(
                draft: draft,
                referenceIDs: selectedMeetingReferenceIDs,
                images: attachedImages
            )
        } else {
            nil
        }
        submitManualSubmission(CodexChatManualSubmission(
            text: submission.text,
            images: submission.images,
            composerSnapshot: composerSnapshot,
            includesCurrentContext: submission.includesCurrentContext
        ))
    }

    func resolveContext(if isRequired: Bool) async throws -> CodexChatContext? {
        guard isRequired else { return nil }
        guard let workspaceID else { throw CodexAppServerError.invalidProtocolResponse }
        return try await contextProvider.currentContext(workspaceID: workspaceID)
    }

    static let maximumAttachedImages = CodexChatImageAttachment.maximumAttachmentCount
}
