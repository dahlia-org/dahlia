import Foundation
import Observation

@MainActor
@Observable
final class CodexChatSessionModel: Identifiable {
    let id: CodexChatSessionID
    let vaultID: UUID?
    private(set) var backendThreadID: String?
    private(set) var didStartBackendThread = false
    private(set) var title: String
    private(set) var messages: [CodexChatMessage]
    var draft = ""

    var selectedModelID: String
    var selectedEffort: String
    private(set) var selectedApprovalMethod: CodexChatApprovalMethod
    private(set) var models: [CodexModel] = []
    private(set) var isLoading = false
    private(set) var isRestoring = false
    private(set) var needsRestore: Bool
    var isGenerating = false
    var errorMessage: String?
    var noticeMessage: String?
    private(set) var activeTurnID: String?
    private(set) var activeTurnHandleID: UUID?
    private(set) var pendingApprovals: [CodexChatApprovalRequest] = []
    private(set) var pendingUserInput: CodexChatUserInputRequest?
    private(set) var respondingApprovalID: String?
    private(set) var respondingUserInputID: String?
    var isPreparingTurn = false
    var isAwaitingTurnOutput = false
    var isFinalizingTurn = false
    var lastSubmittedText: String?
    var attachedImages: [CodexChatImageAttachment] = []
    private(set) var pendingImagePreparationCount = 0
    private(set) var availableMeetingReferences: [CodexChatMeetingReference] = []
    var selectedMeetingReferenceIDs: [UUID] = []
    private(set) var meetingNamesByID: [UUID: String] = [:]
    private(set) var meetingReferencesByID: [UUID: CodexChatMeetingReference] = [:]

    var pendingApproval: CodexChatApprovalRequest? {
        pendingApprovals.first
    }

    var canDecidePendingApproval: Bool {
        guard let pendingApproval else { return false }
        return approvalDecisionReadyID == pendingApproval.id
            && respondingApprovalID == nil
            && !isStopRequested
    }

    var showsStandaloneThinking: Bool {
        isGenerating && (isAwaitingTurnOutput || isFinalizingTurn)
    }

    @ObservationIgnored private let service: any CodexChatServicing
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let contextProvider: any CodexChatContextProviding
    @ObservationIgnored private let streamingUpdateInterval: Duration
    @ObservationIgnored let usageTelemetryReporter: UsageTelemetryReporter
    @ObservationIgnored private var isStopRequested = false
    var isTurnCleanupPending = false
    @ObservationIgnored private var isRequestingTurnHandle = false
    @ObservationIgnored var isReleased = false
    @ObservationIgnored private var didUnsubscribe = false
    @ObservationIgnored private var threadLeaseID: UUID?
    @ObservationIgnored private var approvalDecisionReadyID: String?
    @ObservationIgnored private var approvalRearmTask: Task<Void, Never>?
    var pendingManualInputs: [CodexChatManualSubmission] = []
    @ObservationIgnored var preparingManualComposerSnapshot: CodexChatComposerSnapshot?
    @ObservationIgnored var lastManualSubmission: CodexChatManualSubmission?
    var activeSteeringManualSubmission: CodexChatManualSubmission?
    @ObservationIgnored private var activeTurnSupportsImages: Bool?
    @ObservationIgnored var activeSubmissionID: UUID?
    @ObservationIgnored private var activeResponseID: String?
    @ObservationIgnored var activeOutputItemIDs: Set<String> = []
    @ObservationIgnored var turnOutputGeneration: UInt = 0
    @ObservationIgnored var turnTask: Task<Void, Never>?
    @ObservationIgnored private var steerTask: Task<Void, Never>?
    @ObservationIgnored private var failedSubmission: CodexChatManualSubmission?
    @ObservationIgnored private var threadDidStartHandler: (@MainActor () -> Void)?
    @ObservationIgnored private var generationCompletionHandler: (@MainActor () -> Void)?
    @ObservationIgnored private var syncedApprovalMethod: CodexChatApprovalMethod?
    @ObservationIgnored private var approvalMethodUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var approvalMethodUpdateErrorMessage: String?
    @ObservationIgnored private var approvalMethodSelectionGeneration: UInt = 0
    @ObservationIgnored private var restoreSelectionGeneration: UInt?
    @ObservationIgnored private let vaultSettings: VaultAISettingsModel
    @ObservationIgnored private let runtimeProviderResolver: @Sendable () -> CodexRuntimeProvider
    @ObservationIgnored private var preparedRuntimeProvider: CodexRuntimeProvider?

    var hasPendingGenerationWork: Bool {
        let hasReachablePendingInput = !pendingManualInputs.isEmpty
            && (errorMessage == nil || backendThreadID != nil)
        return isGenerating
            || isTurnCleanupPending
            || steerTask != nil
            || hasReachablePendingInput
    }

    init(
        id: CodexChatSessionID = CodexChatSessionID(),
        vaultID: UUID? = nil,
        backendThreadID: String? = nil,
        title: String = "",
        messages: [CodexChatMessage] = [],
        modelID: String? = nil,
        effort: String? = nil,
        approvalMethod: CodexChatApprovalMethod? = nil,
        service: any CodexChatServicing = CodexChatService.shared,
        settings: AppSettings = .shared,
        vaultSettings: VaultAISettingsModel = .shared,
        runtimeProviderResolver: @escaping @Sendable () -> CodexRuntimeProvider = {
            CodexRuntimeContextStore.shared.provider
        },
        contextProvider: any CodexChatContextProviding = CodexChatContextProvider(),
        streamingUpdateInterval: Duration = .milliseconds(50),
        usageTelemetryReporter: @escaping UsageTelemetryReporter = { event in
            UsageTelemetryService.shared.record(event)
        }
    ) {
        self.id = id
        let resolvedVaultID = vaultID ?? settings.currentVault?.id
        let usesVaultSettings = vaultSettings.vaultID == resolvedVaultID
        self.vaultID = resolvedVaultID
        self.backendThreadID = backendThreadID
        self.title = title
        self.messages = messages
        self.selectedModelID = modelID ?? (usesVaultSettings ? vaultSettings.chatModelID : settings.codexChatModelID)
        self.selectedEffort = effort ?? (usesVaultSettings ? vaultSettings.chatReasoningEffort : settings.codexChatReasoningEffort)
        self.selectedApprovalMethod = approvalMethod ?? .autoReview
        self.needsRestore = backendThreadID != nil && messages.isEmpty && approvalMethod == nil
        self.service = service
        self.settings = settings
        self.vaultSettings = vaultSettings
        self.runtimeProviderResolver = runtimeProviderResolver
        self.contextProvider = contextProvider
        self.streamingUpdateInterval = streamingUpdateInterval
        self.usageTelemetryReporter = usageTelemetryReporter
    }

    func prepare(forceRefresh: Bool = false) async {
        let runtimeProvider = runtimeProviderResolver()
        if let preparedRuntimeProvider, preparedRuntimeProvider != runtimeProvider {
            errorMessage = CodexConfigurationError.providerChanged(preparedRuntimeProvider.displayName).localizedDescription
            return
        }
        guard models.isEmpty || forceRefresh || preparedRuntimeProvider != runtimeProvider else { return }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            unsubscribeIfPossible()
        }
        do {
            let loadedModels = try await service.models(forceRefresh: forceRefresh || preparedRuntimeProvider != runtimeProvider)
            guard runtimeProvider == runtimeProviderResolver() else { return }
            models = loadedModels
            preparedRuntimeProvider = runtimeProvider
            resolveSelections()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restore() async {
        guard !isRestoring else { return }
        guard let backendThreadID, messages.isEmpty else {
            await prepare()
            return
        }
        if restoreSelectionGeneration == nil {
            restoreSelectionGeneration = approvalMethodSelectionGeneration
        }
        guard let selectionGeneration = restoreSelectionGeneration else { return }
        var didRestoreThread = false
        isLoading = true
        isRestoring = true
        errorMessage = nil
        defer {
            isLoading = false
            isRestoring = false
            if didRestoreThread {
                synchronizeApprovalMethodIfNeeded()
            }
            unsubscribeIfPossible()
        }
        do {
            async let availableModels = service.models(forceRefresh: false)
            guard let vaultID else { throw CodexAppServerError.invalidProtocolResponse }
            async let restoredThread = service.resumeThread(id: backendThreadID, vaultID: vaultID)
            let (models, thread) = try await (availableModels, restoredThread)
            try await ensureThreadLease(thread.id)
            self.models = models
            apply(thread)
            restoreApprovalMethod(
                thread.approvalMethod,
                ifSelectionGenerationUnchangedSince: selectionGeneration
            )
            resolveSelections()
            needsRestore = false
            restoreSelectionGeneration = nil
            didRestoreThread = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectModel(_ modelID: String) {
        selectedModelID = modelID
        persistChatModelID(modelID)
        resolveEffort()
        processPendingInputIfPossible()
    }

    func selectEffort(_ effort: String) {
        selectedEffort = effort
        persistChatReasoningEffort(effort)
    }

    var hasApprovalMethodUpdateFailure: Bool {
        approvalMethodUpdateErrorMessage != nil
    }

    func selectApprovalMethod(_ approvalMethod: CodexChatApprovalMethod) {
        approvalMethodSelectionGeneration &+= 1
        guard selectedApprovalMethod != approvalMethod else { return }
        selectedApprovalMethod = approvalMethod
        if syncedApprovalMethod == approvalMethod {
            clearApprovalMethodUpdateError()
            processPendingInputIfPossible()
            return
        }
        synchronizeApprovalMethodIfNeeded()
    }

    func sendDraft() {
        guard canSend else { return }
        let draftSnapshot = draft
        let referenceIDsSnapshot = selectedMeetingReferenceIDs
        let imagesSnapshot = attachedImages
        let composerSnapshot = CodexChatComposerSnapshot(
            draft: draftSnapshot,
            referenceIDs: referenceIDsSnapshot,
            images: imagesSnapshot
        )
        let text = CodexChatMeetingReference.serializedText(
            referenceIDs: referenceIDsSnapshot,
            draft: draftSnapshot
        )
        let submission = CodexChatManualSubmission(
            text: text,
            images: imagesSnapshot,
            composerSnapshot: composerSnapshot
        )
        sendManualSubmission(submission)
    }

    private func sendManualSubmission(
        _ submission: CodexChatManualSubmission,
        reportsUsage: Bool = true
    ) {
        let shouldEnqueue = isGenerating || isTurnCleanupPending
        if shouldEnqueue, let composerSnapshot = submission.composerSnapshot {
            let isDuplicate = preparingManualComposerSnapshot == composerSnapshot
                || activeSteeringManualSubmission?.composerSnapshot == composerSnapshot
                || pendingManualInputs.contains(where: { $0.composerSnapshot == composerSnapshot })
            guard !isDuplicate else { return }
        }
        if reportsUsage {
            usageTelemetryReporter(.aiChatPromptSubmitted)
        }
        if shouldEnqueue {
            enqueueManualInput(submission)
            return
        }
        submitManualSubmission(submission)
    }

    func retry() {
        if let approvalMethodUpdateErrorMessage,
           errorMessage == approvalMethodUpdateErrorMessage {
            clearApprovalMethodUpdateError()
            synchronizeApprovalMethodIfNeeded()
            return
        }
        guard let submission = failedSubmission ?? lastManualSubmission else { return }
        retryManualSubmission(submission)
    }

    func respondToApproval(id: String, decision: CodexChatApprovalDecision) {
        guard respondingApprovalID == nil,
              approvalDecisionReadyID == id,
              let approval = pendingApprovals.first(where: { $0.id == id }),
              approval.actions.contains(where: { $0.decision == decision })
              || approval.rejectionDecision == decision,
              let activeTurnHandleID else { return }
        respondingApprovalID = id
        Task {
            do {
                try await service.decideApproval(
                    turnID: activeTurnHandleID,
                    id: id,
                    decision: decision
                )
            } catch CodexAppServerError.approvalNoLongerPending {
                resolvePendingApproval(id)
            } catch {
                errorMessage = error.localizedDescription
                if respondingApprovalID == id {
                    respondingApprovalID = nil
                }
            }
        }
    }

    func respondToUserInput(id: String, answer: String) {
        guard respondingUserInputID == nil,
              pendingUserInput?.id == id,
              answer.nilIfBlank != nil,
              let activeTurnHandleID else { return }
        respondingUserInputID = id
        Task {
            do {
                try await service.respondToUserInput(
                    turnID: activeTurnHandleID,
                    id: id,
                    answer: answer
                )
            } catch CodexAppServerError.approvalNoLongerPending {
                resolvePendingUserInput(id)
            } catch {
                errorMessage = error.localizedDescription
                if respondingUserInputID == id {
                    respondingUserInputID = nil
                }
            }
        }
    }

    func stop() {
        guard isGenerating, !isStopRequested else { return }
        isStopRequested = true
        let approvals = pendingApprovals
        let activeTask = turnTask
        let localTurnID = activeTurnHandleID
        let mustDrainActiveTask = localTurnID != nil || isRequestingTurnHandle
        let submissionID = activeSubmissionID
        isTurnCleanupPending = true
        activeTask?.cancel()
        Task {
            if let localTurnID {
                await service.stopTurn(localTurnID)
            } else {
                for approval in approvals {
                    await service.respondToApproval(id: approval.id, decision: .cancel)
                }
            }
            guard mustDrainActiveTask else {
                isTurnCleanupPending = false
                finishGeneration(submissionID: submissionID)
                return
            }
            await activeTask?.value
            pendingApprovals.removeAll()
            isTurnCleanupPending = false
            unsubscribeIfPossible()
            processPendingInputIfPossible()
            notifyGenerationCompletionIfIdle()
        }
        finalizeActiveResponseForCancellation()
    }

    func setThreadDidStartHandler(_ handler: @escaping @MainActor () -> Void) {
        threadDidStartHandler = handler
    }

    func setGenerationCompletionHandler(_ handler: @escaping @MainActor () -> Void) {
        generationCompletionHandler = handler
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        steerTask?.cancel()
        steerTask = nil
        pendingManualInputs.removeAll()
        if isGenerating {
            stop()
        }
        unsubscribeIfPossible()
    }

    func addImageData(_ dataItems: [Data]) async {
        guard !isReleased, !Task.isCancelled else { return }
        let acceptedData = acceptedImageCandidates(from: dataItems)
        guard !acceptedData.isEmpty else { return }

        pendingImagePreparationCount += acceptedData.count
        defer { pendingImagePreparationCount -= acceptedData.count }
        let processedImages = await CodexChatImageProcessor.shared.process(acceptedData)
        guard !isReleased, !Task.isCancelled else { return }
        let images = processedImages.compactMap(\.self)
        attachedImages.append(contentsOf: images)
        let failedCount = acceptedData.count - images.count
        if failedCount > 0 {
            noticeMessage = L10n.chatImagesUnavailable(failedCount)
        }
    }

    func addImageURLs(_ urls: [URL]) async {
        guard !isReleased, !Task.isCancelled else { return }
        let acceptedURLs = acceptedImageCandidates(from: urls)
        guard !acceptedURLs.isEmpty else { return }

        pendingImagePreparationCount += acceptedURLs.count
        defer { pendingImagePreparationCount -= acceptedURLs.count }
        let accessedURLs = acceptedURLs.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            for url in accessedURLs {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let processedImages = await CodexChatImageProcessor.shared.process(acceptedURLs)
        guard !isReleased, !Task.isCancelled else { return }
        let images = processedImages.compactMap(\.self)
        attachedImages.append(contentsOf: images)
        let failedCount = acceptedURLs.count - images.count
        if failedCount > 0 {
            noticeMessage = L10n.chatImagesUnavailable(failedCount)
        }
    }

    func removeAttachedImage(id: UUID) {
        attachedImages.removeAll { $0.id == id }
    }

    func reportImageAttachmentFailure() {
        noticeMessage = L10n.chatImagesUnavailable(1)
    }
}

extension CodexChatSessionModel {
    func runTurn(
        text: String?,
        images: [CodexChatImageAttachment] = [],
        composerSnapshot: CodexChatComposerSnapshot?,
        context: CodexChatContext?,
        includesCurrentContext: Bool,
        responseID: String,
        approvalMethod: CodexChatApprovalMethod,
        submissionID: UUID
    ) async -> Bool {
        let accumulator = CodexChatTurnAccumulator()
        let updateLimiter = CodexChatStreamingUpdateLimiter(
            minimumInterval: streamingUpdateInterval
        ) { [weak self, accumulator] in
            self?.updateTurnResponse(id: responseID, from: accumulator)
        }
        do {
            await prepare()
            try ensureSubmissionCanContinue(submissionID)
            let backendThreadID = try await ensureBackendThread(
                text: text,
                images: images,
                submissionID: submissionID
            )
            try await ensureThreadLease(backendThreadID)
            try ensureSubmissionCanContinue(submissionID)

            guard images.isEmpty || selectedModelSupportsImages else {
                noticeMessage = L10n.chatModelDoesNotSupportImages
                recordFailedSubmission(
                    text: text,
                    images: images,
                    includesCurrentContext: includesCurrentContext
                )
                return false
            }
            activeTurnSupportsImages = selectedModelSupportsImages
            let inputs = makeAppServerInputs(
                text: text,
                context: context,
                images: images
            )
            let turn = try await requestTurnHandle(
                threadID: backendThreadID,
                inputs: inputs,
                model: selectedModelID.nilIfBlank,
                effort: selectedEffort,
                approvalMethod: approvalMethod
            )
            applyEffectiveApprovalMethod(turn.approvalMethod ?? approvalMethod, requested: approvalMethod)
            do {
                try ensureSubmissionCanContinue(submissionID)
            } catch {
                await service.stopTurn(turn.id)
                throw error
            }
            activeTurnHandleID = turn.id

            let submission = CodexChatManualSubmission(
                text: text ?? "",
                images: images,
                includesCurrentContext: includesCurrentContext
            )
            clearComposer(ifMatching: composerSnapshot)
            lastSubmittedText = submission.text
            lastManualSubmission = submission
            messages.append(CodexChatMessage(
                role: .user,
                text: submission.text,
                context: context,
                images: images
            ))

            messages.append(CodexChatMessage(id: responseID, role: .assistant, text: "", isStreaming: true))
            activeResponseID = responseID
            isAwaitingTurnOutput = true
            isPreparingTurn = false
            preparingManualComposerSnapshot = nil
            try ensureSubmissionCanContinue(submissionID)
            let turnCompleted = try await consumeTurnEventsRecoveringMissingThread(
                turn,
                retry: MissingThreadRetry(
                    threadID: backendThreadID,
                    inputs: inputs,
                    model: selectedModelID.nilIfBlank,
                    effort: selectedEffort,
                    approvalMethod: approvalMethod
                ),
                accumulator: accumulator,
                updateLimiter: updateLimiter,
                submissionID: submissionID

            )
            updateLimiter.submit(force: true)
            completeTurnResponse(responseID: responseID)
            if turnCompleted {
                isFinalizingTurn = true
                await reconcileFromRollout(
                    preservingReasoningFrom: responseID,
                    submissionID: submissionID
                )
            } else if !isStopRequested,
                      errorMessage != nil {
                recordFailedSubmission(
                    text: text,
                    images: images,
                    includesCurrentContext: includesCurrentContext
                )
            }

            return turnCompleted
        } catch is CancellationError {
            updateLimiter.submit(force: true)
            completeTurnResponse(responseID: responseID)
            return false
        } catch {
            guard activeSubmissionID == submissionID else { return false }
            errorMessage = error.localizedDescription
            recordFailedSubmission(
                text: text,
                images: images,
                includesCurrentContext: includesCurrentContext
            )
            updateLimiter.submit(force: true)
            completeTurnResponse(responseID: responseID)
            return false
        }
    }

    func consumeTurnEvents(
        _ stream: AsyncThrowingStream<CodexChatTurnEvent, any Error>,
        accumulator: CodexChatTurnAccumulator,
        updateLimiter: CodexChatStreamingUpdateLimiter,
        submissionID: UUID

    ) async throws -> Bool {
        var eventsSinceYield = 0
        for try await event in stream {
            try ensureSubmissionCanContinue(submissionID)
            apply(event, accumulator: accumulator, updateLimiter: updateLimiter)
            if let completedSuccessfully = event.terminalCompletion {
                return completedSuccessfully
            }
            eventsSinceYield += 1
            if eventsSinceYield == Self.maximumEventsBetweenYields {
                eventsSinceYield = 0
                await Task.yield()
            }
        }
        return false
    }

    private func apply(
        _ event: CodexChatTurnEvent,
        accumulator: CodexChatTurnAccumulator,
        updateLimiter: CodexChatStreamingUpdateLimiter
    ) {
        switch event {
        case let .started(turnID):
            activeTurnID = turnID
            if isStopRequested, let backendThreadID {
                Task { await service.interrupt(threadID: backendThreadID, turnID: turnID) }
            }
            processPendingInputIfPossible()
        case let .delta(itemID, text):
            accumulator.appendResponseDelta(itemID: itemID, text: text)
            publishStreamingOutput(itemID: itemID, using: updateLimiter)
        case let .completed(itemID?, text):
            accumulator.completeResponse(itemID: itemID, text: text)
            completeStreamingOutput(itemID: itemID, using: updateLimiter)
        case .completed(itemID: nil, text: _):
            updateLimiter.submit(force: true)
            activeOutputItemIDs.removeAll()
            isAwaitingTurnOutput = false
            activeTurnID = nil
        case let .reasoningDelta(itemID, summaryIndex, text):
            accumulator.appendReasoningDelta(itemID: itemID, summaryIndex: summaryIndex, text: text)
            publishStreamingOutput(itemID: itemID, using: updateLimiter)
        case let .reasoningCompleted(itemID, text):
            accumulator.completeReasoning(itemID: itemID, text: text)
            completeStreamingOutput(itemID: itemID, using: updateLimiter)
        case let .approvalRequested(request):
            updateLimiter.submit(force: true)
            if !pendingApprovals.contains(where: { $0.id == request.id }) {
                pendingApprovals.append(request)
                if pendingApprovals.count == 1 {
                    approvalDecisionReadyID = request.id
                }
            }
        case let .userInputRequested(request):
            pendingUserInput = request
        case let .approvalResolved(id):
            resolvePendingApproval(id)
            resolvePendingUserInput(id)
        case .interrupted:
            updateLimiter.submit(force: true)
            activeOutputItemIDs.removeAll()
            isAwaitingTurnOutput = false
            activeTurnID = nil
        case let .failed(message):
            errorMessage = CodexAppServerError.turnFailed(message).localizedDescription
            updateLimiter.submit(force: true)
            activeOutputItemIDs.removeAll()
            isAwaitingTurnOutput = false
            activeTurnID = nil
        }
    }

    private func apply(_ thread: CodexChatThread, preservingPendingMessages: Bool = false) {
        backendThreadID = thread.id
        title = thread.title
        if !preservingPendingMessages {
            messages = thread.messages
        }
        if let model = thread.model?.nilIfBlank {
            selectedModelID = model
        }
        if let effort = thread.reasoningEffort?.nilIfBlank {
            selectedEffort = effort
        }
    }

    private func completeTurnResponse(responseID: String) {
        guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
        messages[index].isStreaming = false
        if messages[index].text.isEmpty, messages[index].reasoning.isEmpty {
            messages.remove(at: index)
        }
    }

    private func finalizeActiveResponseForCancellation() {
        guard let activeResponseID,
              let index = messages.firstIndex(where: { $0.id == activeResponseID }) else { return }
        messages[index].isStreaming = false
        if activeTurnID == nil,
           messages[index].text.isEmpty,
           messages[index].reasoning.isEmpty {
            messages.remove(at: index)
        }
    }

    private func updateTurnResponse(id: String, from accumulator: CodexChatTurnAccumulator) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let responseText = accumulator.responseText
        let reasoningText = accumulator.reasoningText
        if messages[index].text != responseText {
            messages[index].text = responseText
        }
        if messages[index].reasoning != reasoningText {
            messages[index].reasoning = reasoningText
        }
    }

    private func reconcileFromRollout(
        preservingReasoningFrom responseID: String,
        submissionID: UUID
    ) async {
        guard let backendThreadID,
              let thread = try? await service.loadThread(id: backendThreadID)
        else { return }
        guard activeSubmissionID == submissionID, !Task.isCancelled else { return }
        let streamedReasoning = messages
            .first(where: { $0.id == responseID })?
            .reasoning
            .nilIfBlank
        var reconciledMessages = thread.messages
        if let streamedReasoning,
           let index = reconciledMessages.lastIndex(where: { $0.role == .assistant }),
           reconciledMessages[index].reasoning.nilIfBlank == nil {
            reconciledMessages[index].reasoning = streamedReasoning
        }
        let reconciledThread = CodexChatThread(
            id: thread.id,
            title: thread.title,
            messages: reconciledMessages,
            model: thread.model,
            reasoningEffort: thread.reasoningEffort
        )
        apply(reconciledThread, preservingPendingMessages: thread.messages.count < messages.count)
    }

    func finishGeneration(
        submissionID: UUID?
    ) {
        guard activeSubmissionID == submissionID else { return }
        isGenerating = false
        isPreparingTurn = false
        pendingApprovals.removeAll()
        pendingUserInput = nil
        approvalDecisionReadyID = nil
        approvalRearmTask?.cancel()
        approvalRearmTask = nil
        preparingManualComposerSnapshot = nil
        activeOutputItemIDs.removeAll()
        isAwaitingTurnOutput = false
        isFinalizingTurn = false
        activeTurnID = nil
        activeTurnHandleID = nil
        respondingApprovalID = nil
        respondingUserInputID = nil
        isStopRequested = false
        activeTurnSupportsImages = nil
        activeSubmissionID = nil
        activeResponseID = nil
        turnTask = nil
        unsubscribeIfPossible()
        processPendingInputIfPossible()
        notifyGenerationCompletionIfIdle()
    }

    private func notifyGenerationCompletionIfIdle() {
        guard !hasPendingGenerationWork else { return }
        generationCompletionHandler?()
    }

    private func rearmNextApprovalAfterInteractionBoundary() {
        approvalRearmTask?.cancel()
        guard let nextID = pendingApprovals.first?.id else {
            approvalDecisionReadyID = nil
            approvalRearmTask = nil
            return
        }
        approvalDecisionReadyID = nil
        approvalRearmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled,
                  self?.pendingApprovals.first?.id == nextID else { return }
            self?.approvalDecisionReadyID = nextID
            self?.approvalRearmTask = nil
        }
    }

    private func resolvePendingApproval(_ id: String) {
        let wasPresented = pendingApprovals.first?.id == id
        pendingApprovals.removeAll { $0.id == id }
        if respondingApprovalID == id {
            respondingApprovalID = nil
        }
        if wasPresented {
            rearmNextApprovalAfterInteractionBoundary()
        }
    }

    private func resolvePendingUserInput(_ id: String) {
        guard pendingUserInput?.id == id else { return }
        pendingUserInput = nil
        respondingUserInputID = nil
    }

    private static let maximumEventsBetweenYields = 64

    private struct MissingThreadRetry {
        let threadID: String
        let inputs: [CodexAppServerInput]
        let model: String?
        let effort: String
        let approvalMethod: CodexChatApprovalMethod
    }

    private func consumeTurnEventsRecoveringMissingThread(
        _ turn: CodexChatTurnHandle,
        retry: MissingThreadRetry,
        accumulator: CodexChatTurnAccumulator,
        updateLimiter: CodexChatStreamingUpdateLimiter,
        submissionID: UUID

    ) async throws -> Bool {
        do {
            return try await consumeTurnEvents(
                turn.events,
                accumulator: accumulator,
                updateLimiter: updateLimiter,
                submissionID: submissionID

            )
        } catch let error as CodexAppServerError where error.isThreadNotFound {
            guard let vaultID else { throw error }
            let thread = try await service.resumeThread(id: retry.threadID, vaultID: vaultID)
            try ensureSubmissionCanContinue(submissionID)
            apply(thread, preservingPendingMessages: true)
            syncedApprovalMethod = thread.approvalMethod
            let retryTurn = try await requestTurnHandle(
                threadID: thread.id,
                inputs: retry.inputs,
                model: retry.model,
                effort: retry.effort,
                approvalMethod: retry.approvalMethod
            )
            applyEffectiveApprovalMethod(
                retryTurn.approvalMethod ?? retry.approvalMethod,
                requested: retry.approvalMethod
            )
            try ensureSubmissionCanContinue(submissionID)
            activeTurnHandleID = retryTurn.id
            return try await consumeTurnEvents(
                retryTurn.events,
                accumulator: accumulator,
                updateLimiter: updateLimiter,
                submissionID: submissionID

            )
        }
    }

    private func requestTurnHandle(
        threadID: String,
        inputs: [CodexAppServerInput],
        model: String?,
        effort: String,
        approvalMethod: CodexChatApprovalMethod
    ) async throws -> CodexChatTurnHandle {
        isRequestingTurnHandle = true
        defer { isRequestingTurnHandle = false }
        return try await service.beginTurn(
            threadID: threadID,
            inputs: inputs,
            model: model,
            effort: effort,
            approvalMethod: approvalMethod,
            expectedProvider: preparedRuntimeProvider ?? runtimeProviderResolver()
        )
    }

    private func restoreApprovalMethod(
        _ approvalMethod: CodexChatApprovalMethod?,
        ifSelectionGenerationUnchangedSince selectionGeneration: UInt
    ) {
        syncedApprovalMethod = approvalMethod
        if approvalMethodSelectionGeneration == selectionGeneration {
            selectedApprovalMethod = approvalMethod ?? .ask
        }
        synchronizeApprovalMethodIfNeeded()
    }

    private func applyEffectiveApprovalMethod(
        _ effectiveMethod: CodexChatApprovalMethod,
        requested requestedMethod: CodexChatApprovalMethod
    ) {
        syncedApprovalMethod = effectiveMethod
        if selectedApprovalMethod == requestedMethod {
            selectedApprovalMethod = effectiveMethod
        }
        clearApprovalMethodUpdateError()
        synchronizeApprovalMethodIfNeeded()
    }

    func clearApprovalMethodUpdateError() {
        if errorMessage == approvalMethodUpdateErrorMessage {
            errorMessage = nil
        }
        approvalMethodUpdateErrorMessage = nil
    }

    private func synchronizeApprovalMethodIfNeeded() {
        guard !isRestoring,
              !needsRestore,
              backendThreadID != nil,
              syncedApprovalMethod != selectedApprovalMethod,
              approvalMethodUpdateTask == nil else { return }
        approvalMethodUpdateTask = Task {
            await synchronizeApprovalMethod()
        }
    }

    private func synchronizeApprovalMethod() async {
        defer { approvalMethodUpdateTask = nil }
        while !Task.isCancelled,
              let backendThreadID,
              syncedApprovalMethod != selectedApprovalMethod {
            let approvalMethod = selectedApprovalMethod
            do {
                let effectiveMethod = try await service.updateApprovalMethod(
                    threadID: backendThreadID,
                    approvalMethod: approvalMethod
                )
                applyEffectiveApprovalMethod(effectiveMethod, requested: approvalMethod)
            } catch is CancellationError {
                return
            } catch {
                let message = L10n.chatApprovalUpdateFailed(error.localizedDescription)
                approvalMethodUpdateErrorMessage = message
                errorMessage = message
                return
            }
        }
    }

    func ensureBackendThread(
        text: String?,
        images: [CodexChatImageAttachment],
        submissionID: UUID
    ) async throws -> String {
        if let backendThreadID {
            return backendThreadID
        }
        guard isBoundToCurrentVault, let vaultID else {
            throw CodexAppServerError.invalidProtocolResponse
        }
        let thread = try await service.startThread(
            model: selectedModelID.nilIfBlank,
            effort: selectedEffort,
            vaultID: vaultID
        )
        try ensureSubmissionCanContinue(submissionID)
        apply(thread, preservingPendingMessages: true)
        let threadTitle = if let text = text?.nilIfBlank {
            text
        } else if images.isEmpty {
            L10n.newChat
        } else {
            L10n.chatImage
        }
        title = threadTitle
        await service.setThreadName(threadID: thread.id, name: threadTitle)
        try ensureSubmissionCanContinue(submissionID)
        didStartBackendThread = true
        threadDidStartHandler?()
        return thread.id
    }

    func ensureSubmissionCanContinue(_ submissionID: UUID) throws {
        guard activeSubmissionID == submissionID, !Task.isCancelled else {
            throw CancellationError()
        }

        guard !isStopRequested else {
            throw CancellationError()
        }
        if let preparedRuntimeProvider,
           preparedRuntimeProvider != runtimeProviderResolver() {
            throw CodexConfigurationError.providerChanged(preparedRuntimeProvider.displayName)
        }
    }

    func prepareFailureStateForSubmission() {
        failedSubmission = nil
    }

    func recordFailedSubmission(text: String?, images: [CodexChatImageAttachment] = [], includesCurrentContext: Bool = true) {
        if text?.nilIfBlank != nil || !images.isEmpty {
            recordFailedManualSubmission(CodexChatManualSubmission(text: text ?? "", images: images, includesCurrentContext: includesCurrentContext))
        }
    }

    func recordFailedManualSubmission(_ submission: CodexChatManualSubmission) {
        lastSubmittedText = submission.text
        lastManualSubmission = submission
        failedSubmission = submission
    }

    private func unsubscribeIfPossible() {
        guard isReleased,
              !isGenerating,
              !isTurnCleanupPending,
              !isLoading,
              !didUnsubscribe,
              let backendThreadID,
              let threadLeaseID
        else { return }
        didUnsubscribe = true
        self.threadLeaseID = nil
        Task {
            await service.releaseThreadLease(threadID: backendThreadID, leaseID: threadLeaseID)
        }
    }

    private func ensureThreadLease(_ threadID: String) async throws {
        guard threadLeaseID == nil else { return }
        let leaseID = await service.acquireThreadLease(threadID: threadID)
        guard !isReleased else {
            await service.releaseThreadLease(threadID: threadID, leaseID: leaseID)
            throw CancellationError()
        }
        threadLeaseID = leaseID
    }

    private func resolveSelections() {
        guard !models.isEmpty else { return }
        if !models.contains(where: { $0.model == selectedModelID }) {
            selectedModelID = models.first(where: \CodexModel.isDefault)?.model ?? models[0].model
            persistChatModelID(selectedModelID)
        }
        resolveEffort()
    }

    private func resolveEffort() {
        let options = effortOptions
        guard !options.isEmpty else { return }
        if !options.contains(where: { $0.reasoningEffort == selectedEffort }) {
            selectedEffort = options.first(where: { $0.reasoningEffort == CodexReasoningEffortOption.defaultValue })?.reasoningEffort
                ?? models.first(where: { $0.model == selectedModelID })?.defaultReasoningEffort
                ?? options[0].reasoningEffort
        }
        persistChatReasoningEffort(selectedEffort)
    }

    private func persistChatModelID(_ modelID: String) {
        if usesVaultSettings {
            vaultSettings.chatModelID = modelID
        } else {
            settings.codexChatModelID = modelID
        }
    }

    private func persistChatReasoningEffort(_ effort: String) {
        if usesVaultSettings {
            vaultSettings.chatReasoningEffort = effort
        } else {
            settings.codexChatReasoningEffort = effort
        }
    }

    private var usesVaultSettings: Bool {
        vaultSettings.vaultID == vaultID
    }
}

extension CodexChatSessionModel {

    func processPendingInputIfPossible() {
        guard !isReleased,
              isBoundToCurrentVault,
              !isTurnCleanupPending,
              steerTask == nil,
              errorMessage == nil else { return }
        if isGenerating {
            startSteeringPendingInputIfPossible()
        } else if !pendingManualInputs.isEmpty {
            guard pendingManualInputs[0].images.isEmpty || selectedModelSupportsImages else {
                noticeMessage = L10n.chatModelDoesNotSupportImages
                return
            }
            let submission = pendingManualInputs.removeFirst()
            submitManualSubmission(submission)
        }
    }

    func startSteeringPendingInputIfPossible() {
        guard let backendThreadID,
              let activeTurnID,
              let input = nextPendingSteerInput() else { return }
        activeSteeringManualSubmission = input
        steerTask = Task { [weak self] in
            await self?.steer(
                input,
                threadID: backendThreadID,
                turnID: activeTurnID

            )
        }
    }

    func nextPendingSteerInput() -> CodexChatManualSubmission? {
        guard let submission = pendingManualInputs.first,
              submission.images.isEmpty || activeTurnSupportsImages == true else { return nil }
        return pendingManualInputs.removeFirst()
    }

    func steer(
        _ input: CodexChatManualSubmission,
        threadID: String,
        turnID: String

    ) async {
        defer {
            steerTask = nil
            activeSteeringManualSubmission = nil
            processPendingInputIfPossible()
            notifyGenerationCompletionIfIdle()
        }
        do {
            let text = input.text
            let images = input.images
            let context = try await resolveContext(if: input.includesCurrentContext)
            guard !Task.isCancelled,
                  isGenerating,
                  let submissionID = activeSubmissionID,
                  activeTurnID == turnID,
                  backendThreadID == threadID else {
                requeue(input)
                return
            }

            let inputs = makeAppServerInputs(
                text: text,
                context: context,
                images: images
            )
            let outputGeneration = turnOutputGeneration
            try await service.steer(threadID: threadID, turnID: turnID, inputs: inputs)
            await completeSuccessfulSteer(
                input,
                context: context,
                state: CodexChatSteerCompletionState(
                    submissionID: submissionID,
                    threadID: threadID,
                    turnID: turnID,
                    outputGeneration: outputGeneration
                )
            )
        } catch is CancellationError {
            requeue(input)
        } catch {
            await handleSteerFailure(
                error,
                input: input,
                turnID: turnID

            )
        }
    }

    func handleSteerFailure(
        _ error: any Error,
        input: CodexChatManualSubmission,
        turnID: String

    ) async {
        if let serverError = error as? CodexAppServerError,
           serverError.isNoActiveTurnToSteer,
           isGenerating,
           activeTurnID == turnID {
            requeue(input)
            await reloadCompletedTurnAndRestart(turnID: turnID)
        } else if !isGenerating || activeTurnID != turnID {
            requeue(input)
        } else {
            errorMessage = error.localizedDescription
            recordFailedManualSubmission(input)
        }
    }

    func reloadCompletedTurnAndRestart(turnID: String) async {
        guard let backendThreadID,
              let thread = try? await service.loadThread(id: backendThreadID),
              isGenerating,
              activeTurnID == turnID else { return }
        apply(thread)
        activeTurnID = nil
        turnTask?.cancel()
        finalizeActiveResponseForCancellation()
        finishGeneration(submissionID: activeSubmissionID)
    }

    func applySuccessfulSteer(_ submission: CodexChatManualSubmission, context: CodexChatContext?, awaitsOutput: Bool) async {
        clearComposer(ifMatching: submission.composerSnapshot)
        messages.append(CodexChatMessage(role: .user, text: submission.text, context: context, images: submission.images))
        if awaitsOutput { isAwaitingTurnOutput = true }
    }

    func requeue(_ input: CodexChatManualSubmission) {
        guard !isReleased else { return }
        pendingManualInputs.insert(input, at: 0)
    }

}

extension CodexChatSessionModel {
    func updateAvailableMeetings(
        _ references: [CodexChatMeetingReference],
        catalogVaultID: UUID?,
        isCatalogLoaded: Bool = true
    ) {
        guard let vaultID, catalogVaultID == vaultID else { return }
        availableMeetingReferences = references
        for reference in references {
            meetingNamesByID[reference.id] = reference.name
            meetingReferencesByID[reference.id] = reference
        }
        guard isCatalogLoaded else { return }
        let availableIDs = Set(references.map(\.id))
        selectedMeetingReferenceIDs.removeAll { !availableIDs.contains($0) }
    }

    func addMeetingReference(_ reference: CodexChatMeetingReference) {
        guard !selectedMeetingReferenceIDs.contains(reference.id) else { return }
        selectedMeetingReferenceIDs.append(reference.id)
        meetingNamesByID[reference.id] = reference.name
        meetingReferencesByID[reference.id] = reference
    }

    func removeMeetingReference(id: UUID) {
        selectedMeetingReferenceIDs.removeAll { $0 == id }
    }

    func meetingDisplayName(for id: UUID) -> String {
        meetingNamesByID[id] ?? L10n.meetingUnavailable
    }

    func displayText(_ text: String) -> String {
        CodexChatMeetingReference.displayText(for: text, namesByID: meetingNamesByID)
    }
}
