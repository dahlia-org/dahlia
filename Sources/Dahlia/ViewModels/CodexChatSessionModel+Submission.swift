import Foundation

enum CodexChatFailedSubmission {
    case manual(CodexChatManualSubmission)
    case liveTranscript(String)
}

struct CodexChatLiveModeSubmissionState {
    let isEnabled: Bool, includesContext: Bool
    let generation: UInt
}

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
        includesLiveModeContext: Bool,
        liveTranscript: String?,
        images: [CodexChatImageAttachment]
    ) -> [CodexAppServerInput] {
        let textInputs = CodexChatPromptCodec.encodeTextBlocks(
            text: text,
            context: context,
            includesLiveModeContext: includesLiveModeContext,
            liveTranscript: liveTranscript
        ).map(CodexAppServerInput.text)
        return textInputs + images.map { .imageDataURI($0.dataURI) }
    }

    func submit(
        _ text: String,
        images: [CodexChatImageAttachment] = [],
        composerSnapshot: CodexChatComposerSnapshot? = nil,
        liveTranscript: String? = nil
    ) {
        guard isBoundToCurrentVault,
              !isGenerating,
              text.nilIfBlank != nil || !images.isEmpty || liveTranscript?.nilIfBlank != nil else { return }
        guard images.isEmpty || models.isEmpty || selectedModelSupportsImages else {
            noticeMessage = L10n.chatModelDoesNotSupportImages
            return
        }
        prepareFailureStateForSubmission(liveTranscript: liveTranscript)
        isGenerating = true
        isAwaitingTurnOutput = true
        errorMessage = nil
        isActiveTurnLiveTranscript = liveTranscript != nil
        let isLiveModeSnapshot = liveTranscript != nil || isLiveModeEnabled
        let liveModeState = CodexChatLiveModeSubmissionState(
            isEnabled: isLiveModeSnapshot,
            includesContext: liveTranscript != nil && isLiveModeSnapshot && !didSendLiveModeContext,
            generation: liveModeGeneration
        )
        let submissionID = UUID.v7()
        activeSubmissionID = submissionID

        turnTask = Task { [weak self] in
            await self?.resolveContextAndRunTurn(
                text: text,
                images: images,
                composerSnapshot: composerSnapshot,
                liveTranscript: liveTranscript,
                liveModeState: liveModeState,
                submissionID: submissionID
            )
        }
    }

    func resolveContextAndRunTurn(
        text: String,
        images: [CodexChatImageAttachment],
        composerSnapshot: CodexChatComposerSnapshot?,
        liveTranscript: String?,
        liveModeState: CodexChatLiveModeSubmissionState,
        submissionID: UUID
    ) async {
        defer {
            finishGeneration(submissionID: submissionID)
        }
        let shouldResolveContext = !liveModeState.isEnabled || liveModeState.includesContext
        let context: CodexChatContext?
        do {
            context = try await resolveContext(if: shouldResolveContext)
            try ensureSubmissionCanContinue(submissionID, liveTranscript: liveTranscript)
        } catch is CancellationError {
            return
        } catch {
            guard activeSubmissionID == submissionID else { return }
            recordFailedSubmission(text: text, images: images, liveTranscript: liveTranscript)
            errorMessage = error.localizedDescription
            return
        }
        guard !isReleased, isBoundToCurrentVault else { return }
        let responseID = "pending-\(UUID.v7().uuidString)"

        _ = await runTurn(
            text: liveTranscript == nil ? text : nil,
            images: liveTranscript == nil ? images : [],
            composerSnapshot: composerSnapshot,
            liveTranscript: liveTranscript,
            context: context,
            responseID: responseID,
            liveModeState: liveModeState,
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
        submit(
            submission.text,
            images: submission.images,
            composerSnapshot: composerSnapshot
        )
    }

    func resolveContext(if isRequired: Bool) async throws -> CodexChatContext? {
        guard isRequired else { return nil }
        guard let vaultID else { throw CodexAppServerError.invalidProtocolResponse }
        return try await contextProvider.currentContext(vaultID: vaultID)
    }

    static let maximumPendingLiveTranscriptCharacters = 100_000
    static let maximumAttachedImages = CodexChatImageAttachment.maximumAttachmentCount
}
