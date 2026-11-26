import Foundation
import Observation

@MainActor
@Observable
final class CodexChatSessionModel: Identifiable {
    let id: CodexChatSessionID
    let accountID: String
    var contextWorkspaceID: UUID? { settings.currentWorkspace?.id }
    private(set) var isReadOnly = false
    private(set) var backendThreadID: String?
    private(set) var parentThread: CodexChatThreadSummary?
    private(set) var didStartBackendThread = false
    private(set) var title: String
    private(set) var messages: [CodexChatMessage]
    var preparingUserMessage: CodexChatMessage?

    var conversationMessages: [CodexChatMessage] {
        guard let preparingUserMessage else { return messages }
        return messages + [preparingUserMessage]
    }

    private(set) var earlierMessagesCursor: String?
    private(set) var lastLoadedItemSeq: Int64?
    private(set) var isLoadingEarlierMessages = false
    private(set) var earlierMessagesError: String?
    var draft = ""
    /// Armed by `/clear`: the next turn starts a new Pi session while this thread and its history stay.
    var startsFreshSession = false
    var scopeSnapshot: CodexChatScopeSnapshot?
    private(set) var hasSelectedProject = false
    private(set) var selectedScopeProjectID: UUID?

    var selectedModelID: String
    var selectedEffort: String
    private(set) var selectedApprovalMethod: CodexChatApprovalMethod
    private(set) var models: [CodexModel] = []
    private(set) var isLoading = false
    private(set) var isRestoring = false
    @ObservationIgnored private var historySynchronizationGeneration = 0
    /// The service's latest state of this thread, set by the coordinator.
    @ObservationIgnored var runtimeState: CodexChatRuntimeState?
    /// The last run this view showed to its end, and the last settled run it reloaded history for.
    @ObservationIgnored private var displayedRunID: UUID?
    @ObservationIgnored private var synchronizedRunID: UUID?
    /// True while this view follows a run it did not start; such a run never changes the user's model or effort.
    @ObservationIgnored private var isFollowingRun = false
    /// Set when this view lost events of a run; cleared once it has the run's snapshot or its saved history.
    @ObservationIgnored private var lostRunEvents = false
    private(set) var needsRestore: Bool
    var isGenerating = false
    var errorMessage: String?
    var noticeMessage: String?
    /// MCP servers the open chat process cannot use until the user signs in; reported again at each turn.
    var mcpServersNeedingSignIn: [String] = []
    private(set) var toolActivity: CodexChatToolActivity?
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
    var pendingImagePreparationCount = 0
    private(set) var availableMeetingReferences: [CodexChatMeetingReference] = []
    var selectedMeetingReferenceIDs: [UUID] = []
    var selectedThreadReferences: [CodexChatThreadSummary] = []
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
        // A running compaction shows its own progress row.
        isGenerating && !isCompacting && (isPreparingTurn || isAwaitingTurnOutput || isFinalizingTurn)
    }

    private(set) var isCompacting = false

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
    var deliveryMode: CodexChatDeliveryMode {
        get { settings.chatDeliveryMode }
        set { settings.chatDeliveryMode = newValue }
    }

    var isQueuePaused = false
    var editingPendingInputID: UUID?
    var pendingInputEditDraft = ""
    var pendingInputEditImages: [CodexChatImageAttachment] = []
    var pendingManualInputs: [CodexChatManualSubmission] = []
    @ObservationIgnored var preparingQueuedManualSubmission: CodexChatManualSubmission?
    @ObservationIgnored var preparingManualComposerSnapshot: CodexChatComposerSnapshot?
    @ObservationIgnored var lastManualSubmission: CodexChatManualSubmission?
    var activeSteeringManualSubmission: CodexChatManualSubmission?
    @ObservationIgnored private var referenceWorkspaceIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var activeTurnSupportsImages: Bool?
    @ObservationIgnored private var activeTurnIsCommand = false
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
    @ObservationIgnored private let workspaceSettings: WorkspaceAISettingsModel
    @ObservationIgnored private var preparedModelsGeneration: Int?

    var hasRecoverablePendingInputs: Bool {
        !pendingManualInputs.isEmpty && (errorMessage == nil || backendThreadID != nil)
    }

    var hasPendingGenerationWork: Bool {
        let hasReachablePendingInput = !isQueuePaused && editingPendingInputID == nil && hasRecoverablePendingInputs
        return isGenerating
            || isTurnCleanupPending
            || steerTask != nil
            || hasReachablePendingInput
    }

    init(
        id: CodexChatSessionID = CodexChatSessionID(),
        accountID: String? = nil,
        backendThreadID: String? = nil,
        title: String = "",
        messages: [CodexChatMessage] = [],
        modelID: String? = nil,
        effort: String? = nil,
        approvalMethod: CodexChatApprovalMethod? = nil,
        service: any CodexChatServicing = PiChatService.shared,
        settings: AppSettings = .shared,
        workspaceSettings: WorkspaceAISettingsModel = .shared,
        contextProvider: any CodexChatContextProviding = CodexChatContextProvider(),
        streamingUpdateInterval: Duration = .milliseconds(50),
        usageTelemetryReporter: @escaping UsageTelemetryReporter = { event in
            UsageTelemetryService.shared.record(event)
        }
    ) {
        self.id = id
        let resolvedWorkspaceID = settings.currentWorkspace?.id
        let usesWorkspaceSettings = workspaceSettings.workspaceID == resolvedWorkspaceID
        self.accountID = accountID ?? AppAccount.key
        self.backendThreadID = backendThreadID
        self.title = title
        self.messages = messages
        self.selectedModelID = modelID ?? (usesWorkspaceSettings ? workspaceSettings.chatModelID : settings.codexChatModelID)
        self.selectedEffort = effort ?? (usesWorkspaceSettings ? workspaceSettings.chatReasoningEffort : settings.codexChatReasoningEffort)
        self.selectedApprovalMethod = approvalMethod ?? .autoReview
        self.needsRestore = backendThreadID != nil && messages.isEmpty && approvalMethod == nil
        self.service = service
        self.settings = settings
        self.workspaceSettings = workspaceSettings
        self.contextProvider = contextProvider
        self.streamingUpdateInterval = streamingUpdateInterval
        self.usageTelemetryReporter = usageTelemetryReporter
    }

    func selectScopeProject(_ projectID: UUID?) {
        guard canSelectScope, projectID == nil || scopeSnapshot?.projects.contains(where: { $0.id == projectID }) == true else { return }
        selectedScopeProjectID = projectID
        hasSelectedProject = true
    }

    func slashCommands() async throws -> [CodexChatSlashCommand] {
        guard isBoundToCurrentAccount, !isReleased else { return [] }
        let commands = try await service.commands(threadID: backendThreadID)
        try Task.checkCancellation()
        guard !isReleased else { throw CancellationError() }
        // Dahlia's `/clear` replaces any Pi command of that name, which would act on a session the thread still treats as live.
        guard canStartFreshSession else { return commands }
        return [Self.clearCommand] + commands.filter { $0.name != Self.clearCommand.name }
    }

    static var clearCommand: CodexChatSlashCommand {
        CodexChatSlashCommand(name: "clear", description: L10n.chatClearCommandDescription, source: "dahlia")
    }

    /// Arms `/clear` and removes the command from the draft; references and images stay for the next message.
    func armFreshSession() {
        guard canStartFreshSession else { return }
        startsFreshSession = true
        draft = ""
    }

    /// A conversation with nothing earlier has no context to clear.
    var canStartFreshSession: Bool {
        backendThreadID != nil && !isReadOnly && (!messages.isEmpty || earlierMessagesCursor != nil)
    }

    func prepare(forceRefresh: Bool = false) async {
        // A chat that was hidden when the models changed (it missed `modelsDidChange`) lists the new ones when it shows.
        let modelsGeneration = PiRuntimeService.modelsGeneration.withLock { $0 }
        guard models.isEmpty
            || forceRefresh
            || preparedModelsGeneration != modelsGeneration
        else { return }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            unsubscribeIfPossible()
        }
        do {
            let loadedModels = try await service.models(forceRefresh: forceRefresh)
            models = loadedModels
            preparedModelsGeneration = modelsGeneration
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
            async let restoredThread = service.resumeThread(id: backendThreadID)
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
            Task { await self.synchronizeThread() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadEarlierMessages() async {
        guard !isReleased, !isGenerating, !isRestoring, !isLoadingEarlierMessages,
              let threadID = backendThreadID, let cursor = earlierMessagesCursor else { return }
        isLoadingEarlierMessages = true
        earlierMessagesError = nil
        defer { isLoadingEarlierMessages = false }
        do {
            let page = try await service.loadEarlierMessages(threadID: threadID, cursor: cursor)
            try Task.checkCancellation()
            guard !isReleased, !isGenerating, backendThreadID == threadID, earlierMessagesCursor == cursor else { return }
            messages = CodexChatMessage.prependingHistory(page.messages, to: messages)
            earlierMessagesCursor = page.earlierCursor
        } catch is CancellationError {
            // Closing or switching a conversation cancels only its display projection.
        } catch {
            guard !isReleased, backendThreadID == threadID else { return }
            earlierMessagesError = error.localizedDescription
        }
    }

    func selectModel(_ modelID: String) {
        selectedModelID = modelID
        persistChatModelID(modelID)
        resolveEffort()
        persistChatReasoningEffort(selectedEffort)
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
        sendDraft(mode: deliveryMode)
    }

    func sendDraft(commandPressed: Bool) {
        sendDraft(mode: isGenerating ? deliveryMode.resolved(commandPressed: commandPressed) : deliveryMode)
    }

    func sendDraft(mode: CodexChatDeliveryMode) {
        guard canSend else { return }
        if canStartFreshSession, draft.trimmingCharacters(in: .whitespacesAndNewlines) == "/" + Self.clearCommand.name {
            armFreshSession()
            return
        }
        let draftSnapshot = draft
        let referenceIDsSnapshot = selectedMeetingReferenceIDs
        let imagesSnapshot = attachedImages
        let composerSnapshot = CodexChatComposerSnapshot(
            draft: draftSnapshot,
            referenceIDs: referenceIDsSnapshot,
            images: imagesSnapshot,
            threadReferences: selectedThreadReferences
        )
        let text = serializedComposerText
        let submission = CodexChatManualSubmission(
            deliveryMode: mode,
            text: text,
            images: imagesSnapshot,
            composerSnapshot: composerSnapshot,
            // Pi dispatches commands only at the start of the message, before any Dahlia context.
            includesCurrentContext: !draftSnapshot.hasPrefix("/")
        )
        sendManualSubmission(submission)
    }

    private func sendManualSubmission(
        _ submission: CodexChatManualSubmission,
        reportsUsage: Bool = true
    ) {
        let shouldEnqueue = isGenerating || isTurnCleanupPending || (errorMessage == nil && !pendingManualInputs.isEmpty)
        if shouldEnqueue, let composerSnapshot = submission.composerSnapshot {
            let isDuplicate = (activeSteeringManualSubmission?.clearsComposerOnDelivery == true
                && activeSteeringManualSubmission?.composerSnapshot == composerSnapshot)
                || pendingManualInputs.contains(where: { $0.clearsComposerOnDelivery && $0.composerSnapshot == composerSnapshot })
            guard !isDuplicate else { return }
        }
        if reportsUsage {
            usageTelemetryReporter(.aiChatPromptSubmitted)
        }
        var submission = submission
        submission.startsFreshSession = startsFreshSession
        startsFreshSession = false
        isQueuePaused = false
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
            } catch PiRuntimeError.approvalNoLongerPending {
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
            } catch PiRuntimeError.approvalNoLongerPending {
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
        isQueuePaused = true
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

    /// Add a removable reference to another conversation.
    func addThreadReference(_ thread: CodexChatThreadSummary) {
        guard !selectedThreadReferences.contains(where: { $0.id == thread.id }) else { return }
        selectedThreadReferences.append(thread)
    }

    func referenceThreads(cursor: String?) async throws -> CodexChatThreadPage {
        guard isBoundToCurrentAccount else { throw PiRuntimeError.backendResetForSafety }
        return try await service.listThreads(cursor: cursor)
    }

    /// Follows the service's state of this thread: reloads history when a run this view did not show has settled, and
    /// attaches to a run that is active. Nothing else changes this view, so another thread's activity never does.
    func synchronizeThread() async {
        guard isBoundToCurrentAccount, !isReleased, !isGenerating, !isRestoring, let threadID = backendThreadID else { return }
        historySynchronizationGeneration += 1
        let generation = historySynchronizationGeneration
        let state = runtimeState
        do {
            var attachment: CodexChatTurnHandle?
            if state?.status != "settled", state?.status != "queued" { attachment = try await service.attach(threadID: threadID) }
            // A run this view already showed to its end, such as one it just stopped, is not followed again while it winds down.
            if let id = attachment?.id, id == displayedRunID { return }
            guard let handle = attachment else {
                let settledUnseen = state.map { $0.status == "settled" && $0.turnID != displayedRunID && $0.turnID != synchronizedRunID } ?? false
                guard settledUnseen || lostRunEvents else { return }
                let thread = try await service.loadThread(id: threadID)
                guard generation == historySynchronizationGeneration,
                      isBoundToCurrentAccount, !isReleased, !isGenerating, !isRestoring else { return }
                if let state, state.status == "settled" { synchronizedRunID = state.turnID }
                lostRunEvents = false
                apply(thread, keepingSelection: true)
                return
            }
            guard generation == historySynchronizationGeneration,
                  isBoundToCurrentAccount, !isReleased, !isGenerating else { return }
            try await ensureThreadLease(threadID)
            guard generation == historySynchronizationGeneration,
                  isBoundToCurrentAccount, !isReleased, !isGenerating else { return }
            if let snapshot = handle.snapshot { apply(snapshot, keepingSelection: true) }
            lostRunEvents = false
            isFollowingRun = true
            let submissionID = UUID.v7()
            let responseID = UUID.v7().uuidString
            activeSubmissionID = submissionID
            activeTurnHandleID = handle.id
            activeTurnIsCommand = handle.isCommand
            isGenerating = true
            isAwaitingTurnOutput = true
            isStopRequested = false
            if let method = handle.approvalMethod { selectedApprovalMethod = method
                syncedApprovalMethod = method
            }
            messages.append(CodexChatMessage(
                id: responseID,
                role: .assistant,
                text: "",
                isStreaming: true,
                runID: activeTurnHandleID,
                timestamp: .now
            ))
            activeResponseID = responseID
            turnTask = Task { [weak self] in
                guard let self else { return }
                let accumulator = CodexChatTurnAccumulator()
                let limiter = CodexChatStreamingUpdateLimiter(minimumInterval: streamingUpdateInterval) { [weak self, accumulator] in
                    self?.updateTurnResponse(id: responseID, from: accumulator)
                }
                do {
                    _ = try await consumeTurnEvents(handle.events, accumulator: accumulator, updateLimiter: limiter, submissionID: submissionID)
                    limiter.submit(force: true)
                    completeTurnResponse(responseID: responseID, accumulator: accumulator)
                    if !isReleased { await reconcileFromRollout(preservingReasoningFrom: responseID, submissionID: submissionID) }
                } catch is CancellationError {
                    limiter.submit(force: true)
                    completeTurnResponse(responseID: responseID, accumulator: accumulator)
                } catch {
                    limiter.submit(force: true)
                    completeTurnResponse(responseID: responseID, accumulator: accumulator)
                    errorMessage = error.localizedDescription
                }
                finishGeneration(submissionID: submissionID)
            }
        } catch {
            if generation == historySynchronizationGeneration, !isReleased { errorMessage = error.localizedDescription }
        }
    }

    func release(stoppingRun: Bool = false) {
        guard !isReleased else { return }
        isReleased = true
        steerTask?.cancel()
        steerTask = nil
        pendingManualInputs.removeAll()
        if isGenerating {
            if stoppingRun {
                stop()
            } else if !isRequestingTurnHandle {
                turnTask?.cancel()
                finishGeneration(submissionID: activeSubmissionID)
            }
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
                context: context,
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
            activeTurnIsCommand = text?.hasPrefix("/") == true
            let inputs = makeAppServerInputs(
                text: text,
                context: context,
                images: images
            )
            let startsFreshSession = preparingUserMessage?.startsFreshSession == true
            let turn: CodexChatTurnHandle
            do {
                turn = try await requestTurnHandle(
                    threadID: backendThreadID,
                    inputs: inputs,
                    model: selectedModelID.nilIfBlank,
                    effort: selectedEffort,
                    approvalMethod: approvalMethod,
                    startsFreshSession: startsFreshSession
                )
            } catch let error as CodexChatFreshSessionCommittedError {
                preparingUserMessage?.startsFreshSession = false
                throw error.underlyingError
            }
            preparingUserMessage?.startsFreshSession = false
            preparingQueuedManualSubmission = nil
            applyEffectiveApprovalMethod(turn.approvalMethod ?? approvalMethod, requested: approvalMethod)
            do {
                try ensureSubmissionCanContinue(submissionID)
            } catch {
                if !isReleased || isStopRequested {
                    await service.stopTurn(turn.id)
                }
                throw error
            }
            activeTurnHandleID = turn.id

            let submission = CodexChatManualSubmission(
                text: text ?? "",
                images: images,
                includesCurrentContext: includesCurrentContext
            )
            lastSubmittedText = submission.text
            lastManualSubmission = submission
            var userMessage = CodexChatMessage(
                id: preparingUserMessage?.id ?? UUID.v7().uuidString,
                role: .user,
                text: submission.text,
                context: context,
                images: images,
                runID: turn.id,
                timestamp: preparingUserMessage?.timestamp ?? .now
            )
            userMessage.startsFreshSession = startsFreshSession
            messages.append(userMessage)
            preparingUserMessage = nil

            messages.append(CodexChatMessage(
                id: responseID,
                role: .assistant,
                text: "",
                isStreaming: true,
                runID: activeTurnHandleID,
                timestamp: .now
            ))
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
            completeTurnResponse(responseID: responseID, accumulator: accumulator)
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
            completeTurnResponse(responseID: responseID, accumulator: accumulator)
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
            completeTurnResponse(responseID: responseID, accumulator: accumulator)
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
        do {
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
        } catch is ChatTurnBroadcast.ReaderOverflow {
            try ensureSubmissionCanContinue(submissionID)
            lostRunEvents = true
            // The service still owns the run. Recover its projection without offering to resend the input.
        }
        return false
    }

    private func apply(
        _ event: CodexChatTurnEvent,
        accumulator: CodexChatTurnAccumulator,
        updateLimiter: CodexChatStreamingUpdateLimiter
    ) {
        if event.terminalCompletion != nil { toolActivity = nil }
        switch event {
        case let .started(turnID):
            activeTurnID = turnID
            noticeMessage = nil
            mcpServersNeedingSignIn = []
            if isStopRequested, let backendThreadID {
                Task { await service.interrupt(threadID: backendThreadID, turnID: turnID) }
            }
            processPendingInputIfPossible()
        case let .delta(itemID, text):
            markResponseAfterTools()
            if toolActivity != nil { toolActivity = nil }
            accumulator.appendResponseDelta(itemID: itemID, text: text)
            publishStreamingOutput(itemID: itemID, using: updateLimiter)
        case let .completed(itemID?, text):
            markResponseAfterTools()
            if toolActivity != nil { toolActivity = nil }
            accumulator.completeResponse(itemID: itemID, text: text)
            completeStreamingOutput(itemID: itemID, using: updateLimiter)
        case .completed(itemID: nil, text: _), .interrupted:
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
        case let .toolActivity(activity):
            toolActivity = activity
            recordToolActivity(activity)
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
        case let .failed(message):
            errorMessage = PiRuntimeError.turnFailed(message).localizedDescription
            updateLimiter.submit(force: true)
            activeOutputItemIDs.removeAll()
            isAwaitingTurnOutput = false
            activeTurnID = nil
        case let .mcpSignInRequired(servers):
            mcpServersNeedingSignIn = servers
        case let .notice(message, level):
            insertBeforeActiveResponse(CodexChatMessage(role: .notice(level), text: message))
        case .compactionStarted:
            isCompacting = true
            insertBeforeActiveResponse(CodexChatMessage(role: .compaction(nil), text: "", runID: activeTurnHandleID))
        case let .compactionEnded(compaction):
            endCompaction(compaction)
        }
    }

    /// The progress row becomes the result, or goes away when the compaction failed or was stopped.
    private func endCompaction(_ compaction: CodexChatCompaction?) {
        isCompacting = false
        guard let index = messages.lastIndex(where: { $0.role == .compaction(nil) }) else { return }
        if let compaction {
            messages[index] = CodexChatMessage(
                id: messages[index].id, role: .compaction(compaction), text: "", runID: messages[index].runID, timestamp: .now
            )
        } else {
            messages.remove(at: index)
        }
    }

    private func insertBeforeActiveResponse(_ notice: CodexChatMessage) {
        if let index = messages.firstIndex(where: {
            $0.id == activeResponseID && $0.text.isEmpty && $0.reasoning.isEmpty
        }) {
            messages.insert(notice, at: index)
        } else {
            messages.append(notice)
        }
    }

    /// `keepingSelection` is for following a run this view did not start: the model and effort stay as the user left them.
    private func apply(_ thread: CodexChatThread, preservingPendingMessages: Bool = false, keepingSelection: Bool = false) {
        historySynchronizationGeneration += 1
        backendThreadID = thread.id
        parentThread = thread.parentThread
        isReadOnly = thread.isReadOnly
        title = thread.title
        if !preservingPendingMessages {
            messages = thread.messages
            lastLoadedItemSeq = thread.lastItemSeq
            earlierMessagesCursor = thread.earlierMessagesCursor
            earlierMessagesError = nil
        }
        guard !keepingSelection else { return }
        if let model = thread.model?.nilIfBlank {
            selectedModelID = model
        }
        if let effort = thread.reasoningEffort?.nilIfBlank {
            selectedEffort = effort
        }
    }

    private func markResponseAfterTools() {
        guard let index = messages.firstIndex(where: { $0.id == activeResponseID }) else { return }
        messages[index].endsWithToolActivity = false
    }

    private func completeTurnResponse(responseID: String, accumulator: CodexChatTurnAccumulator) {
        guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
        messages[index].isStreaming = false
        // Saved responses are stamped when they end; the collapsed steps measure up to this.
        messages[index].timestamp = .now
        if !messages[index].hasResponseContent {
            messages.remove(at: index)
        } else if !messages[index].endsWithToolActivity, accumulator.responseParts.count > 1 {
            let steps = CodexChatMessage(
                id: responseID + "-steps", role: .assistant,
                text: accumulator.responseParts.dropLast().joined(separator: "\n\n"),
                runID: messages[index].runID
            )
            messages[index].text = accumulator.responseParts.last ?? ""
            messages.insert(steps, at: index)
        }
    }

    private func finalizeActiveResponseForCancellation() {
        guard let activeResponseID,
              let index = messages.firstIndex(where: { $0.id == activeResponseID }) else { return }
        messages[index].isStreaming = false
        if activeTurnID == nil, !messages[index].hasResponseContent {
            messages.remove(at: index)
        }
    }

    private func updateTurnResponse(id: String, from accumulator: CodexChatTurnAccumulator) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        MainActorHangMonitor.shared.measure(.chat) { applyTurnResponse(at: index, from: accumulator) }
    }

    private func applyTurnResponse(at index: Int, from accumulator: CodexChatTurnAccumulator) {
        let responseText = accumulator.responseText
        let reasoningText = accumulator.reasoningText
        if messages[index].text != responseText {
            messages[index].text = responseText
        }
        if messages[index].reasoning != reasoningText {
            messages[index].reasoning = reasoningText
        }
    }

    private func recordToolActivity(_ activity: CodexChatToolActivity) {
        let existing = activity.callID.flatMap { callID in
            messages.lastIndex { $0.runID == activeTurnHandleID && $0.toolActivities.contains { $0.callID == callID } }
        }
        guard let index = existing ?? messages.lastIndex(where: { $0.role == .assistant && $0.runID == activeTurnHandleID }) else { return }
        messages[index].recordToolActivity(activity)
    }

    private func reconcileFromRollout(
        preservingReasoningFrom responseID: String,
        submissionID: UUID
    ) async {
        guard let backendThreadID,
              let thread = try? await service.loadThread(id: backendThreadID)
        else { return }
        guard activeSubmissionID == submissionID, !Task.isCancelled, !isReleased else { return }
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
        var reconciledThread = thread
        reconciledThread.messages = reconciledMessages
        // Pi does not write handled commands or their notifications into its rollout.
        let hasNotices = messages.contains { if case .notice = $0.role { true } else { false } }
        apply(
            reconciledThread, preservingPendingMessages: hasNotices || thread.messages.count < messages.count, keepingSelection: isFollowingRun
        )
        // Reconciliation observed this saved boundary even when notices or older messages keep the streamed projection.
        lastLoadedItemSeq = thread.lastItemSeq
    }

    func finishGeneration(
        submissionID: UUID?
    ) {
        guard activeSubmissionID == submissionID else { return }
        let restoresQueuedInput = isStopRequested && preparingQueuedManualSubmission != nil
        if isStopRequested, let preparingQueuedManualSubmission {
            requeue(preparingQueuedManualSubmission)
        }
        preparingQueuedManualSubmission = nil
        if !hasComposerContent, pendingImagePreparationCount == 0, pendingManualInputs.isEmpty,
           let snapshot = preparingManualComposerSnapshot {
            draft = snapshot.draft
            selectedMeetingReferenceIDs = snapshot.referenceIDs
            selectedThreadReferences = snapshot.threadReferences
            attachedImages = snapshot.images
        }
        // A cancelled direct submission returns to the composer; failed and queued inputs retain their own intent.
        if isStopRequested, !restoresQueuedInput, preparingUserMessage?.startsFreshSession == true { startsFreshSession = true }
        preparingUserMessage = nil
        historySynchronizationGeneration += 1
        // What this view showed to the end needs no reload; it also holds what history does not, such as command notices.
        if !lostRunEvents, let runID = activeTurnHandleID { displayedRunID = runID }
        isFollowingRun = false
        isGenerating = false
        endCompaction(nil)
        toolActivity = nil
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
        activeTurnIsCommand = false
        activeSubmissionID = nil
        activeResponseID = nil
        turnTask = nil
        unsubscribeIfPossible()
        processPendingInputIfPossible()
        notifyGenerationCompletionIfIdle()
        Task { await self.synchronizeThread() }
    }

    func notifyGenerationCompletionIfIdle() {
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
        } catch let error as PiRuntimeError where error.isThreadNotFound {
            let thread = try await service.resumeThread(id: retry.threadID)
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
            let previousRunID = activeTurnHandleID
            activeTurnHandleID = retryTurn.id
            for index in messages.indices where previousRunID != nil && messages[index].runID == previousRunID {
                messages[index].runID = retryTurn.id
            }
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
        approvalMethod: CodexChatApprovalMethod,
        startsFreshSession: Bool = false
    ) async throws -> CodexChatTurnHandle {
        isRequestingTurnHandle = true
        defer { isRequestingTurnHandle = false }
        return try await service.beginTurn(
            threadID: threadID,
            inputs: inputs,
            model: model,
            effort: effort,
            approvalMethod: approvalMethod,
            startsFreshSession: startsFreshSession
        )
    }

    private func restoreApprovalMethod(
        _ approvalMethod: CodexChatApprovalMethod?,
        ifSelectionGenerationUnchangedSince selectionGeneration: UInt
    ) {
        syncedApprovalMethod = approvalMethod
        if approvalMethodSelectionGeneration == selectionGeneration {
            selectedApprovalMethod = approvalMethod ?? .autoReview
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
        context: CodexChatContext?,
        submissionID: UUID
    ) async throws -> String {
        if let backendThreadID {
            return backendThreadID
        }
        guard isBoundToCurrentAccount else {
            throw PiRuntimeError.invalidProtocolResponse
        }
        let thread = try await service.startThread(
            model: selectedModelID.nilIfBlank,
            effort: selectedEffort,
            context: hasSelectedProject ? selectedScopeContext() : context ?? scopeProjectContext
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
        guard activeSubmissionID == submissionID, !Task.isCancelled, !isReleased else {
            throw CancellationError()
        }

        guard !isStopRequested else {
            throw CancellationError()
        }
    }

    func prepareFailureStateForSubmission() {
        failedSubmission = nil
    }

    func recordFailedSubmission(text: String?, images: [CodexChatImageAttachment] = [], includesCurrentContext: Bool = true) {
        if text?.nilIfBlank != nil || !images.isEmpty {
            recordFailedManualSubmission(CodexChatManualSubmission(
                startsFreshSession: preparingUserMessage?.startsFreshSession == true,
                text: text ?? "", images: images, includesCurrentContext: includesCurrentContext
            ))
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
            let request = CodexAppServerRequest(model: selectedModelID, developerInstructions: "", inputs: [], outputSchema: Data())
            selectedModelID = (try? PiRuntimeService.resolvedModel(for: request, in: models))?.model
                ?? PiRuntimeService.ownProvidersFirst(models, \.first)?.model ?? models[0].model
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
    }

    private func persistChatModelID(_ modelID: String) {
        if usesWorkspaceSettings {
            workspaceSettings.chatModelID = modelID
        } else {
            settings.codexChatModelID = modelID
        }
    }

    private func persistChatReasoningEffort(_ effort: String) {
        if usesWorkspaceSettings {
            workspaceSettings.chatReasoningEffort = effort
        } else {
            settings.codexChatReasoningEffort = effort
        }
    }

    private var usesWorkspaceSettings: Bool {
        workspaceSettings.workspaceID == contextWorkspaceID
    }
}

extension CodexChatSessionModel {

    func processPendingInputIfPossible() {
        guard !isReleased,
              isBoundToCurrentAccount,
              !isTurnCleanupPending,
              steerTask == nil,
              errorMessage == nil else { return }
        if isGenerating {
            startSteeringPendingInputIfPossible()
        } else if !isQueuePaused, !pendingManualInputs.isEmpty {
            guard pendingManualInputs[0].id != editingPendingInputID else { return }
            if let message = compactImageValidationMessage(text: pendingManualInputs[0].text, hasImages: !pendingManualInputs[0].images.isEmpty) {
                noticeMessage = message
                return
            }
            guard pendingManualInputs[0].images.isEmpty || selectedModelSupportsImages else {
                noticeMessage = L10n.chatModelDoesNotSupportImages
                return
            }
            let submission = pendingManualInputs.removeFirst()
            submitManualSubmission(submission, fromQueue: true)
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
        // A steer would reach the session `/clear` is about to leave; the input waits to start the new one.
        guard !activeTurnIsCommand, !startsFreshSession,
              let index = pendingManualInputs.prefix(while: { !$0.startsFreshSession }).firstIndex(where: { $0.deliveryMode == .steer }),
              pendingManualInputs[index].id != editingPendingInputID,
              !isQueuePaused else { return nil }
        let submission = pendingManualInputs[index]
        guard !submission.text.hasPrefix("/"),
              submission.images.isEmpty || activeTurnSupportsImages == true else { return nil }
        return pendingManualInputs.remove(at: index)
    }

    var pendingCommand: CodexChatManualSubmission? {
        pendingManualInputs.first { $0.text.hasPrefix("/") }
    }

    func cancelPendingCommand(_ command: CodexChatManualSubmission) {
        removePendingInput(id: command.id)
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
                  !isQueuePaused,
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
        if let serverError = error as? PiRuntimeError,
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
        if submission.clearsComposerOnDelivery { clearComposer(ifMatching: submission.composerSnapshot) }
        messages.append(CodexChatMessage(
            role: .user,
            text: submission.text,
            context: context,
            images: submission.images,
            isSteer: true,
            runID: activeTurnHandleID,
            timestamp: .now
        ))
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
        catalogWorkspaceID: UUID?,
        isCatalogLoaded: Bool = true
    ) {
        guard isBoundToCurrentAccount, let workspaceID = contextWorkspaceID, catalogWorkspaceID == workspaceID else { return }
        availableMeetingReferences = references
        for reference in references {
            referenceWorkspaceIDs[reference.id] = workspaceID
            meetingNamesByID[reference.id] = reference.name
            meetingReferencesByID[reference.id] = reference
        }
        guard isCatalogLoaded else { return }
        let availableIDs = Set(references.map(\.id))
        selectedMeetingReferenceIDs.removeAll { referenceWorkspaceIDs[$0] == workspaceID && !availableIDs.contains($0) }
    }

    func addMeetingReference(_ reference: CodexChatMeetingReference) {
        guard !selectedMeetingReferenceIDs.contains(reference.id) else { return }
        selectedMeetingReferenceIDs.append(reference.id)
        referenceWorkspaceIDs[reference.id] = contextWorkspaceID
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
