extension CodexChatSessionModel {
    var displayTitle: String {
        displayText(title.nilIfBlank ?? L10n.newChat)
    }

    var canSend: Bool {
        !isReadOnly
            && !isRestoring
            && !needsRestore
            && isBoundToCurrentAccount
            && pendingImagePreparationCount == 0
            && (attachedImages.isEmpty || selectedModelSupportsImages)
            && hasComposerContent
    }

    var hasComposerContent: Bool {
        draft.nilIfBlank != nil || !selectedMeetingReferenceIDs.isEmpty || !selectedThreadReferences.isEmpty || !attachedImages.isEmpty
    }

    var selectedModelSupportsImages: Bool {
        models.first(where: { $0.model == selectedModelID })?.supportsImages == true
    }

    var attachmentValidationMessage: String? {
        if pendingImagePreparationCount > 0 {
            L10n.chatPreparingImages
        } else if !attachedImages.isEmpty,
                  models.contains(where: { $0.model == selectedModelID }),
                  !selectedModelSupportsImages {
            L10n.chatModelDoesNotSupportImages
        } else {
            nil
        }
    }

    var hasRetryableSubmission: Bool {
        hasApprovalMethodUpdateFailure || lastSubmittedText != nil
    }

    var effortOptions: [CodexReasoningEffortOption] {
        guard let model = models.first(where: { $0.model == selectedModelID }) else { return [] }
        return model.supportedReasoningEfforts.isEmpty
            ? [CodexReasoningEffortOption(reasoningEffort: model.defaultReasoningEffort, description: "")]
            : model.supportedReasoningEfforts
    }

    var isBoundToCurrentAccount: Bool {
        accountID == CodexRuntimeProvider.local.accountKey
    }
}
