import Foundation
import Observation

private enum CodexChatFailedSubmission {
    case manual(String)
    case liveTranscript(String)
}

private struct CodexChatLiveModeSubmissionState {
    let isEnabled: Bool
    let includesContext: Bool
    let generation: UInt
}

@MainActor
@Observable
final class CodexChatSessionModel: Identifiable {
    let id: CodexChatSessionID
    let vaultID: UUID?
    private(set) var backendThreadID: String?
    private(set) var title: String
    private(set) var messages: [CodexChatMessage]
    var draft = "" {
        didSet {
            if draft.nilIfBlank == nil {
                sendNextLiveTranscriptIfPossible()
            }
        }
    }

    var selectedModelID: String
    var selectedEffort: String
    private(set) var models: [CodexModel] = []
    private(set) var isLoading = false
    private(set) var isGenerating = false
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?
    private(set) var activeTurnID: String?
    private(set) var lastSubmittedText: String?
    private(set) var failedLiveTranscript: String?
    private(set) var availableMeetingReferences: [CodexChatMeetingReference] = []
    private(set) var selectedMeetingReferenceIDs: [UUID] = []
    private(set) var meetingNamesByID: [UUID: String] = [:]
    private(set) var meetingReferencesByID: [UUID: CodexChatMeetingReference] = [:]
    private(set) var isLiveModeEnabled = false

    var liveModeEnabled: Bool {
        get { isLiveModeEnabled }
        set { setLiveModeEnabled(newValue) }
    }

    @ObservationIgnored private let service: any CodexChatServicing
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let contextProvider: any CodexChatContextProviding
    @ObservationIgnored private let streamingUpdateInterval: Duration
    @ObservationIgnored private var isStopRequested = false
    @ObservationIgnored private var isReleased = false
    @ObservationIgnored private var didUnsubscribe = false
    @ObservationIgnored private var pendingLiveTranscript: String?
    @ObservationIgnored private var didTruncatePendingLiveTranscript = false
    @ObservationIgnored private var pendingManualInputs: [String] = []
    @ObservationIgnored private var isActiveTurnLiveTranscript = false
    @ObservationIgnored private var didSendLiveModeContext = false
    @ObservationIgnored private var liveModeGeneration: UInt = 0
    @ObservationIgnored private var activeSteerIsLiveTranscript = false
    @ObservationIgnored private var activeSubmissionID: UUID?
    @ObservationIgnored private var activeResponseID: String?
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var steerTask: Task<Void, Never>?
    @ObservationIgnored private var failedSubmission: CodexChatFailedSubmission?
    @ObservationIgnored private var usesLiveModePlaceholderTitle = false
    @ObservationIgnored private var liveModeChangeHandler: (@MainActor (Bool) -> Void)?

    init(
        id: CodexChatSessionID = CodexChatSessionID(),
        vaultID: UUID? = nil,
        backendThreadID: String? = nil,
        title: String = "",
        messages: [CodexChatMessage] = [],
        modelID: String? = nil,
        effort: String? = nil,
        service: any CodexChatServicing = CodexChatService.shared,
        settings: AppSettings = .shared,
        contextProvider: any CodexChatContextProviding = CodexChatContextProvider(),
        streamingUpdateInterval: Duration = .milliseconds(50)
    ) {
        self.id = id
        self.vaultID = vaultID ?? settings.currentVault?.id
        self.backendThreadID = backendThreadID
        self.title = title
        self.messages = messages
        self.selectedModelID = modelID ?? settings.codexChatModelID
        self.selectedEffort = effort ?? settings.codexChatReasoningEffort
        self.service = service
        self.settings = settings
        self.contextProvider = contextProvider
        self.streamingUpdateInterval = streamingUpdateInterval
    }

    func prepare(forceRefresh: Bool = false) async {
        guard models.isEmpty || forceRefresh else { return }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            unsubscribeIfPossible()
        }
        do {
            models = try await service.models(forceRefresh: forceRefresh)
            resolveSelections()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restore() async {
        guard let backendThreadID, messages.isEmpty else {
            await prepare()
            return
        }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            unsubscribeIfPossible()
        }
        do {
            async let availableModels = service.models(forceRefresh: false)
            guard let vaultID else { throw CodexAppServerError.invalidProtocolResponse }
            async let restoredThread = service.resumeThread(id: backendThreadID, vaultID: vaultID)
            let (models, thread) = try await (availableModels, restoredThread)
            self.models = models
            apply(thread)
            resolveSelections()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectModel(_ modelID: String) {
        selectedModelID = modelID
        settings.codexChatModelID = modelID
        resolveEffort()
    }

    func selectEffort(_ effort: String) {
        selectedEffort = effort
        settings.codexChatReasoningEffort = effort
    }

    func sendDraft() {
        guard canSend else { return }
        let draftSnapshot = draft
        let referenceIDsSnapshot = selectedMeetingReferenceIDs
        let text = CodexChatMeetingReference.serializedText(
            referenceIDs: referenceIDsSnapshot,
            draft: draftSnapshot
        )
        if isGenerating {
            enqueueManualInput(
                text,
                draftSnapshot: draftSnapshot,
                referenceIDsSnapshot: referenceIDsSnapshot
            )
            return
        }
        submit(
            text,
            clearsDraft: true,
            draftSnapshot: draftSnapshot,
            referenceIDsSnapshot: referenceIDsSnapshot
        )
    }

    func retry() {
        switch failedSubmission {
        case let .liveTranscript(failedLiveTranscript):
            self.failedLiveTranscript = nil
            failedSubmission = nil
            submit("", clearsDraft: false, liveTranscript: failedLiveTranscript)
        case let .manual(text):
            failedSubmission = nil
            retryManualSubmission(text)
        case nil:
            guard let lastSubmittedText else { return }
            retryManualSubmission(lastSubmittedText)
        }
    }

    func stop() {
        guard isGenerating, !isStopRequested else { return }
        isStopRequested = true
        turnTask?.cancel()
        if let backendThreadID, let activeTurnID {
            Task { await service.interrupt(threadID: backendThreadID, turnID: activeTurnID) }
        }
        finalizeActiveResponseForCancellation()
        finishGeneration(submissionID: activeSubmissionID)
    }

    func toggleLiveMode() {
        setLiveModeEnabled(!isLiveModeEnabled)
    }

    func disableLiveMode() {
        setLiveModeEnabled(false)
    }

    func receiveFinalizedLiveTranscript(_ text: String, wasTruncated: Bool = false) {
        guard isLiveModeEnabled,
              isBoundToCurrentVault,
              let text = text.nilIfBlank else { return }
        if wasTruncated {
            noticeMessage = L10n.chatLiveTranscriptBacklogTruncated
        }
        appendPendingLiveTranscript(text)
        sendNextLiveTranscriptIfPossible()
    }

    func setLiveModeChangeHandler(_ handler: @escaping @MainActor (Bool) -> Void) {
        liveModeChangeHandler = handler
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        steerTask?.cancel()
        steerTask = nil
        pendingManualInputs.removeAll()
        pendingLiveTranscript = nil
        if isGenerating {
            stop()
        }
        unsubscribeIfPossible()
    }
}

private extension CodexChatSessionModel {
    func runTurn(
        text: String?,
        liveTranscript: String?,
        context: CodexChatContext?,
        responseID: String,
        liveModeState: CodexChatLiveModeSubmissionState,
        submissionID: UUID
    ) async -> Bool {
        let accumulator = CodexChatTurnAccumulator()
        let updateLimiter = CodexChatStreamingUpdateLimiter(
            minimumInterval: streamingUpdateInterval
        ) { [weak self, accumulator] in
            self?.updateTurnResponse(id: responseID, from: accumulator)
        }
        do {
            if models.isEmpty {
                await prepare()
            }
            try ensureSubmissionCanContinue(submissionID, liveTranscript: liveTranscript)
            let backendThreadID = try await ensureBackendThread(
                text: text,
                liveTranscript: liveTranscript,
                submissionID: submissionID
            )
            try ensureSubmissionCanContinue(submissionID, liveTranscript: liveTranscript)

            let promptContext = liveModeState.isEnabled && !liveModeState.includesContext ? nil : context
            let stream = try await service.send(
                threadID: backendThreadID,
                textBlocks: CodexChatPromptCodec.encodeTextBlocks(
                    text: text,
                    context: promptContext,
                    includesLiveModeContext: liveModeState.includesContext,
                    liveTranscript: liveTranscript
                ),
                model: selectedModelID.nilIfBlank,
                effort: selectedEffort
            )
            if liveModeState.includesContext,
               isLiveModeEnabled,
               liveModeGeneration == liveModeState.generation {
                didSendLiveModeContext = true
            }
            try ensureSubmissionCanContinue(submissionID, liveTranscript: liveTranscript)
            let turnCompleted = try await consumeTurnEvents(
                stream,
                accumulator: accumulator,
                updateLimiter: updateLimiter,
                submissionID: submissionID,
                liveTranscript: liveTranscript
            )
            updateLimiter.submit(force: true)
            completeTurnResponse(responseID: responseID)
            if turnCompleted {
                await reconcileFromRollout(
                    preservingReasoningFrom: responseID,
                    submissionID: submissionID
                )
            } else if !isStopRequested,
                      errorMessage != nil || liveTranscript != nil {
                recordFailedSubmission(text: text, liveTranscript: liveTranscript)
            }
            return turnCompleted
        } catch is CancellationError {
            updateLimiter.submit(force: true)
            completeTurnResponse(responseID: responseID)
            return false
        } catch {
            guard activeSubmissionID == submissionID else { return false }
            errorMessage = error.localizedDescription
            recordFailedSubmission(text: text, liveTranscript: liveTranscript)
            updateLimiter.submit(force: true)
            completeTurnResponse(responseID: responseID)
            return false
        }
    }

    func consumeTurnEvents(
        _ stream: AsyncThrowingStream<CodexChatTurnEvent, any Error>,
        accumulator: CodexChatTurnAccumulator,
        updateLimiter: CodexChatStreamingUpdateLimiter,
        submissionID: UUID,
        liveTranscript: String?
    ) async throws -> Bool {
        var eventsSinceYield = 0
        for try await event in stream {
            try ensureSubmissionCanContinue(submissionID, liveTranscript: liveTranscript)
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
            updateLimiter.submit()
        case let .completed(itemID?, text):
            accumulator.completeResponse(itemID: itemID, text: text)
            updateLimiter.submit(force: true)
        case .completed(itemID: nil, text: _):
            updateLimiter.submit(force: true)
        case let .reasoningDelta(itemID, summaryIndex, text):
            accumulator.appendReasoningDelta(itemID: itemID, summaryIndex: summaryIndex, text: text)
            updateLimiter.submit()
        case let .reasoningCompleted(itemID, text):
            accumulator.completeReasoning(itemID: itemID, text: text)
            updateLimiter.submit(force: true)
        case .interrupted:
            updateLimiter.submit(force: true)
        case let .failed(message):
            errorMessage = CodexAppServerError.turnFailed(message).localizedDescription
            updateLimiter.submit(force: true)
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

    private func finishGeneration(
        submissionID: UUID?
    ) {
        guard activeSubmissionID == submissionID else { return }
        isGenerating = false
        activeTurnID = nil
        isStopRequested = false
        isActiveTurnLiveTranscript = false
        activeSubmissionID = nil
        activeResponseID = nil
        turnTask = nil
        unsubscribeIfPossible()
        processPendingInputIfPossible()
    }

    private static let maximumEventsBetweenYields = 64

    func ensureBackendThread(
        text: String?,
        liveTranscript: String?,
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
        try ensureSubmissionCanContinue(submissionID, liveTranscript: liveTranscript)
        apply(thread, preservingPendingMessages: true)
        let threadTitle = liveTranscript == nil ? text ?? L10n.newChat : L10n.chatLiveMode
        title = threadTitle
        await service.setThreadName(threadID: thread.id, name: threadTitle)
        usesLiveModePlaceholderTitle = liveTranscript != nil
        try ensureSubmissionCanContinue(submissionID, liveTranscript: liveTranscript)
        return thread.id
    }

    func ensureSubmissionCanContinue(_ submissionID: UUID, liveTranscript: String?) throws {
        guard activeSubmissionID == submissionID, !Task.isCancelled else {
            throw CancellationError()
        }
        guard liveTranscript == nil || isLiveModeEnabled, !isStopRequested else {
            throw CancellationError()
        }
    }

    func retryManualSubmission(_ text: String) {
        let currentText = CodexChatMeetingReference.serializedText(
            referenceIDs: selectedMeetingReferenceIDs,
            draft: draft
        )
        submit(
            text,
            clearsDraft: currentText == text,
            draftSnapshot: draft,
            referenceIDsSnapshot: selectedMeetingReferenceIDs
        )
    }

    func prepareFailureStateForSubmission(liveTranscript: String?) {
        if liveTranscript == nil, let failedLiveTranscript {
            appendPendingLiveTranscript(failedLiveTranscript)
            self.failedLiveTranscript = nil
        }
        failedSubmission = nil
    }

    func recordFailedSubmission(text: String?, liveTranscript: String?) {
        if let liveTranscript, isLiveModeEnabled {
            recordFailedLiveTranscript(liveTranscript)
        } else if let text = text?.nilIfBlank {
            lastSubmittedText = text
            failedSubmission = .manual(text)
        }
    }

    func recordFailedLiveTranscript(_ text: String) {
        failedLiveTranscript = text
        failedSubmission = .liveTranscript(text)
    }

    func replaceLiveModePlaceholderTitleIfNeeded(with text: String) async -> Bool {
        guard usesLiveModePlaceholderTitle,
              let backendThreadID else { return false }
        usesLiveModePlaceholderTitle = false
        title = text
        await service.setThreadName(threadID: backendThreadID, name: text)
        return true
    }

    private func unsubscribeIfPossible() {
        guard isReleased,
              !isGenerating,
              !isLoading,
              !didUnsubscribe,
              let backendThreadID
        else { return }
        didUnsubscribe = true
        Task { await service.unsubscribe(threadID: backendThreadID) }
    }

    private func resolveSelections() {
        guard !models.isEmpty else { return }
        if !models.contains(where: { $0.model == selectedModelID }) {
            selectedModelID = models.first(where: \CodexModel.isDefault)?.model ?? models[0].model
            settings.codexChatModelID = selectedModelID
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
        settings.codexChatReasoningEffort = selectedEffort
    }
}

private extension CodexChatSessionModel {
    func submit(
        _ text: String,
        clearsDraft: Bool,
        draftSnapshot: String? = nil,
        referenceIDsSnapshot: [UUID] = [],
        liveTranscript: String? = nil
    ) {
        guard isBoundToCurrentVault,
              !isGenerating,
              text.nilIfBlank != nil || liveTranscript?.nilIfBlank != nil else { return }
        prepareFailureStateForSubmission(liveTranscript: liveTranscript)
        isGenerating = true
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
                clearsDraft: clearsDraft,
                draftSnapshot: draftSnapshot ?? text,
                referenceIDsSnapshot: referenceIDsSnapshot,
                liveTranscript: liveTranscript,
                liveModeState: liveModeState,
                submissionID: submissionID
            )
        }
    }

    func resolveContextAndRunTurn(
        text: String,
        clearsDraft: Bool,
        draftSnapshot: String,
        referenceIDsSnapshot: [UUID],
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
            recordFailedSubmission(text: text, liveTranscript: liveTranscript)
            errorMessage = error.localizedDescription
            return
        }
        guard !isReleased, isBoundToCurrentVault else { return }
        if clearsDraft {
            clearComposer(
                draftSnapshot: draftSnapshot,
                referenceIDsSnapshot: referenceIDsSnapshot
            )
        }
        var replacedLiveModePlaceholderTitle = false
        if liveTranscript == nil {
            lastSubmittedText = text
            messages.append(CodexChatMessage(role: .user, text: text, context: context))
            replacedLiveModePlaceholderTitle = await replaceLiveModePlaceholderTitleIfNeeded(with: text)
            guard activeSubmissionID == submissionID, !Task.isCancelled else { return }
        }
        let responseID = "pending-\(UUID.v7().uuidString)"
        messages.append(CodexChatMessage(id: responseID, role: .assistant, text: "", isStreaming: true))
        activeResponseID = responseID

        _ = await runTurn(
            text: liveTranscript == nil ? text : nil,
            liveTranscript: liveTranscript,
            context: context,
            responseID: responseID,
            liveModeState: liveModeState,
            submissionID: submissionID
        )
        if replacedLiveModePlaceholderTitle {
            title = text
        }
    }

    func setLiveModeEnabled(_ isEnabled: Bool) {
        guard isLiveModeEnabled != isEnabled else { return }
        isLiveModeEnabled = isEnabled
        liveModeGeneration &+= 1
        didSendLiveModeContext = false
        if !isEnabled {
            if activeSteerIsLiveTranscript {
                steerTask?.cancel()
            }
            pendingLiveTranscript = nil
            failedLiveTranscript = nil
            failedSubmission = nil
            didTruncatePendingLiveTranscript = false
            noticeMessage = nil
            if isGenerating, isActiveTurnLiveTranscript {
                stop()
            }
        }
        liveModeChangeHandler?(isEnabled)
    }

    func enqueueManualInput(
        _ text: String,
        draftSnapshot: String,
        referenceIDsSnapshot: [UUID]
    ) {
        lastSubmittedText = text
        pendingManualInputs.append(text)
        clearComposer(
            draftSnapshot: draftSnapshot,
            referenceIDsSnapshot: referenceIDsSnapshot
        )
        processPendingInputIfPossible()
    }

    func clearComposer(
        draftSnapshot: String,
        referenceIDsSnapshot: [UUID]
    ) {
        if draft == draftSnapshot {
            draft = ""
        }
        if selectedMeetingReferenceIDs == referenceIDsSnapshot {
            selectedMeetingReferenceIDs = []
        }
    }

    func processPendingInputIfPossible() {
        guard !isReleased,
              isBoundToCurrentVault,
              steerTask == nil,
              errorMessage == nil else { return }
        if isGenerating {
            startSteeringPendingInputIfPossible()
        } else if !pendingManualInputs.isEmpty {
            let text = pendingManualInputs.removeFirst()
            submit(text, clearsDraft: false)
        } else {
            sendNextLiveTranscriptIfPossible()
        }
    }

    func startSteeringPendingInputIfPossible() {
        guard let backendThreadID,
              let activeTurnID,
              let input = dequeuePendingSteerInput() else { return }
        let liveModeGenerationSnapshot = liveModeGeneration
        activeSteerIsLiveTranscript = input.isLiveTranscript
        steerTask = Task { [weak self] in
            await self?.steer(
                input,
                threadID: backendThreadID,
                turnID: activeTurnID,
                liveModeGenerationSnapshot: liveModeGenerationSnapshot
            )
        }
    }

    func dequeuePendingSteerInput() -> CodexChatPendingInput? {
        if !pendingManualInputs.isEmpty {
            return .manual(pendingManualInputs.removeFirst())
        }
        guard isLiveModeEnabled,
              failedLiveTranscript == nil,
              let transcript = pendingLiveTranscript else { return nil }
        pendingLiveTranscript = nil
        let wasTruncated = didTruncatePendingLiveTranscript
        didTruncatePendingLiveTranscript = false
        return .liveTranscript(transcript, wasTruncated: wasTruncated)
    }

    func steer(
        _ input: CodexChatPendingInput,
        threadID: String,
        turnID: String,
        liveModeGenerationSnapshot: UInt
    ) async {
        defer {
            steerTask = nil
            activeSteerIsLiveTranscript = false
            processPendingInputIfPossible()
        }
        do {
            guard !input.isLiveTranscript || isLiveModeEnabled else { return }
            let text = input.manualText
            let liveTranscript = input.liveTranscript
            let isLiveModeSnapshot = isLiveModeEnabled
            let includesLiveModeContext = liveTranscript != nil
                && isLiveModeSnapshot
                && liveModeGeneration == liveModeGenerationSnapshot
                && !didSendLiveModeContext
            let shouldResolveContext = !isLiveModeSnapshot || includesLiveModeContext
            let context = try await resolveContext(if: shouldResolveContext)
            guard !Task.isCancelled,
                  isGenerating,
                  activeTurnID == turnID,
                  backendThreadID == threadID else {
                requeue(input, liveModeGenerationSnapshot: liveModeGenerationSnapshot)
                return
            }

            let promptContext = isLiveModeSnapshot && !includesLiveModeContext ? nil : context
            try await service.steer(
                threadID: threadID,
                turnID: turnID,
                textBlocks: CodexChatPromptCodec.encodeTextBlocks(
                    text: text,
                    context: promptContext,
                    includesLiveModeContext: includesLiveModeContext,
                    liveTranscript: liveTranscript
                )
            )
            if input.isLiveTranscript {
                guard !Task.isCancelled,
                      isLiveModeEnabled,
                      liveModeGeneration == liveModeGenerationSnapshot else { return }
            }
            if includesLiveModeContext {
                didSendLiveModeContext = true
            }
            await applySuccessfulSteer(input, context: promptContext)
        } catch is CancellationError {
            requeue(input, liveModeGenerationSnapshot: liveModeGenerationSnapshot)
        } catch {
            handleSteerFailure(
                error,
                input: input,
                turnID: turnID,
                liveModeGenerationSnapshot: liveModeGenerationSnapshot
            )
        }
    }

    func resolveContext(if isRequired: Bool) async throws -> CodexChatContext? {
        guard isRequired else { return nil }
        guard let vaultID else { throw CodexAppServerError.invalidProtocolResponse }
        return try await contextProvider.currentContext(vaultID: vaultID)
    }

    func handleSteerFailure(
        _ error: any Error,
        input: CodexChatPendingInput,
        turnID: String,
        liveModeGenerationSnapshot: UInt
    ) {
        if let serverError = error as? CodexAppServerError,
           serverError.isNoActiveTurnToSteer,
           isGenerating,
           activeTurnID == turnID {
            activeTurnID = nil
            requeue(input, liveModeGenerationSnapshot: liveModeGenerationSnapshot)
            turnTask?.cancel()
            finalizeActiveResponseForCancellation()
            finishGeneration(submissionID: activeSubmissionID)
        } else if !isGenerating || activeTurnID != turnID {
            requeue(input, liveModeGenerationSnapshot: liveModeGenerationSnapshot)
        } else {
            errorMessage = error.localizedDescription
            recordSteerFailure(input)
        }
    }

    func applySuccessfulSteer(_ input: CodexChatPendingInput, context: CodexChatContext?) async {
        switch input {
        case let .manual(text):
            messages.append(CodexChatMessage(role: .user, text: text, context: context))
            _ = await replaceLiveModePlaceholderTitleIfNeeded(with: text)
        case let .liveTranscript(_, wasTruncated):
            if wasTruncated {
                noticeMessage = L10n.chatLiveTranscriptBacklogTruncated
            }
        }
    }

    func recordSteerFailure(_ input: CodexChatPendingInput) {
        switch input {
        case let .manual(text):
            recordFailedSubmission(text: text, liveTranscript: nil)
        case let .liveTranscript(text, _):
            recordFailedSubmission(text: nil, liveTranscript: text)
        }
    }

    func requeue(_ input: CodexChatPendingInput, liveModeGenerationSnapshot: UInt? = nil) {
        guard !isReleased else { return }
        switch input {
        case let .manual(text):
            pendingManualInputs.insert(text, at: 0)
        case let .liveTranscript(text, wasTruncated):
            if let liveModeGenerationSnapshot,
               !isLiveModeEnabled || liveModeGeneration != liveModeGenerationSnapshot {
                return
            }
            let combined = pendingLiveTranscript.map { text + "\n" + $0 } ?? text
            pendingLiveTranscript = String(combined.suffix(Self.maximumPendingLiveTranscriptCharacters))
            didTruncatePendingLiveTranscript = wasTruncated
                || combined.count > Self.maximumPendingLiveTranscriptCharacters
                || didTruncatePendingLiveTranscript
        }
    }

    func sendNextLiveTranscriptIfPossible() {
        guard isLiveModeEnabled,
              !isReleased,
              errorMessage == nil,
              failedLiveTranscript == nil,
              let transcript = pendingLiveTranscript else { return }
        if isGenerating {
            startSteeringPendingInputIfPossible()
            return
        }
        pendingLiveTranscript = nil
        let wasTruncated = didTruncatePendingLiveTranscript
        didTruncatePendingLiveTranscript = false
        submit(
            "",
            clearsDraft: false,
            liveTranscript: transcript
        )
        if wasTruncated {
            noticeMessage = L10n.chatLiveTranscriptBacklogTruncated
        }
    }

    func appendPendingLiveTranscript(_ text: String) {
        let combined = pendingLiveTranscript.map { $0 + "\n" + text } ?? text
        guard combined.count > Self.maximumPendingLiveTranscriptCharacters else {
            pendingLiveTranscript = combined
            return
        }
        pendingLiveTranscript = String(combined.suffix(Self.maximumPendingLiveTranscriptCharacters))
        didTruncatePendingLiveTranscript = true
    }

    static let maximumPendingLiveTranscriptCharacters = 100_000
}

extension CodexChatSessionModel {
    var displayTitle: String {
        displayText(title.nilIfBlank ?? L10n.newChat)
    }

    var canSend: Bool {
        isBoundToCurrentVault
            && (draft.nilIfBlank != nil || !selectedMeetingReferenceIDs.isEmpty)
    }

    var hasRetryableSubmission: Bool {
        failedLiveTranscript != nil || lastSubmittedText != nil
    }

    var effortOptions: [CodexReasoningEffortOption] {
        guard let model = models.first(where: { $0.model == selectedModelID }) else { return [] }
        return model.supportedReasoningEfforts.isEmpty
            ? [CodexReasoningEffortOption(reasoningEffort: model.defaultReasoningEffort, description: "")]
            : model.supportedReasoningEfforts
    }

    var isBoundToCurrentVault: Bool {
        vaultID != nil && vaultID == settings.currentVault?.id
    }
}

extension CodexChatSessionModel {
    func updateAvailableMeetings(
        _ meetings: [MeetingOverviewItem],
        catalogVaultID: UUID?,
        isCatalogLoaded: Bool = true
    ) {
        guard let vaultID, catalogVaultID == vaultID else { return }
        let references = meetings
            .filter { $0.vaultId == vaultID }
            .map(CodexChatMeetingReference.init)
        availableMeetingReferences = references
        for reference in references {
            meetingNamesByID[reference.id] = reference.name
            meetingReferencesByID[reference.id] = reference
        }
        guard isCatalogLoaded else { return }
        let availableIDs = Set(references.map(\.id))
        selectedMeetingReferenceIDs.removeAll { !availableIDs.contains($0) }
        sendNextLiveTranscriptIfPossible()
    }

    func addMeetingReference(_ reference: CodexChatMeetingReference) {
        guard !selectedMeetingReferenceIDs.contains(reference.id) else { return }
        selectedMeetingReferenceIDs.append(reference.id)
        meetingNamesByID[reference.id] = reference.name
        meetingReferencesByID[reference.id] = reference
    }

    func removeMeetingReference(id: UUID) {
        selectedMeetingReferenceIDs.removeAll { $0 == id }
        sendNextLiveTranscriptIfPossible()
    }

    func meetingDisplayName(for id: UUID) -> String {
        meetingNamesByID[id] ?? L10n.meetingUnavailable
    }

    func displayText(_ text: String) -> String {
        CodexChatMeetingReference.displayText(for: text, namesByID: meetingNamesByID)
    }
}
