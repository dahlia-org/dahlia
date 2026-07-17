import Foundation
import Observation

@MainActor
@Observable
final class CodexChatSessionModel: Identifiable {
    let id: CodexChatSessionID
    let vaultID: UUID?
    private(set) var backendThreadID: String?
    private(set) var title: String
    private(set) var messages: [CodexChatMessage]
    var draft = ""
    var selectedModelID: String
    var selectedEffort: String
    private(set) var models: [CodexModel] = []
    private(set) var isLoading = false
    private(set) var isGenerating = false
    private(set) var errorMessage: String?
    private(set) var activeTurnID: String?
    private(set) var lastSubmittedText: String?
    private(set) var availableMeetingReferences: [CodexChatMeetingReference] = []
    private(set) var selectedMeetingReferenceIDs: [UUID] = []
    private(set) var meetingNamesByID: [UUID: String] = [:]
    private(set) var meetingReferencesByID: [UUID: CodexChatMeetingReference] = [:]

    @ObservationIgnored private let service: any CodexChatServicing
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let contextProvider: any CodexChatContextProviding
    @ObservationIgnored private let streamingUpdateInterval: Duration
    @ObservationIgnored private var isStopRequested = false
    @ObservationIgnored private var isReleased = false
    @ObservationIgnored private var didUnsubscribe = false

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
        submit(
            text,
            clearsDraft: true,
            draftSnapshot: draftSnapshot,
            referenceIDsSnapshot: referenceIDsSnapshot
        )
    }

    func retry() {
        guard let lastSubmittedText else { return }
        let currentText = CodexChatMeetingReference.serializedText(
            referenceIDs: selectedMeetingReferenceIDs,
            draft: draft
        )
        submit(
            lastSubmittedText,
            clearsDraft: currentText == lastSubmittedText,
            draftSnapshot: draft,
            referenceIDsSnapshot: selectedMeetingReferenceIDs
        )
    }

    func stop() {
        guard isGenerating, !isStopRequested else { return }
        isStopRequested = true
        guard let backendThreadID, let activeTurnID else { return }
        Task { await service.interrupt(threadID: backendThreadID, turnID: activeTurnID) }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        if isGenerating {
            stop()
        }
        unsubscribeIfPossible()
    }
}

private extension CodexChatSessionModel {
    func runTurn(text: String, context: CodexChatContext?, responseID: String) async {
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
            try Task.checkCancellation()
            if backendThreadID == nil {
                guard isBoundToCurrentVault, let vaultID else {
                    throw CodexAppServerError.invalidProtocolResponse
                }
                let thread = try await service.startThread(
                    model: selectedModelID.nilIfBlank,
                    effort: selectedEffort,
                    vaultID: vaultID
                )
                apply(thread, preservingPendingMessages: true)
                title = text
                await service.setThreadName(threadID: thread.id, name: text)
            }
            guard let backendThreadID else {
                throw CodexAppServerError.invalidProtocolResponse
            }

            let stream = try await service.send(
                threadID: backendThreadID,
                textBlocks: CodexChatPromptCodec.encodeTextBlocks(text: text, context: context),
                model: selectedModelID.nilIfBlank,
                effort: selectedEffort
            )
            let turnCompleted = try await consumeTurnEvents(
                stream,
                accumulator: accumulator,
                updateLimiter: updateLimiter
            )
            updateLimiter.submit(force: true)
            completeTurnResponse(responseID: responseID)
            if turnCompleted {
                await reconcileFromRollout(preservingReasoningFrom: responseID)
            }
        } catch is CancellationError {
            updateLimiter.submit(force: true)
            completeTurnResponse(responseID: responseID)
        } catch {
            errorMessage = error.localizedDescription
            updateLimiter.submit(force: true)
            completeTurnResponse(responseID: responseID)
        }
        finishGeneration()
    }

    func consumeTurnEvents(
        _ stream: AsyncThrowingStream<CodexChatTurnEvent, any Error>,
        accumulator: CodexChatTurnAccumulator,
        updateLimiter: CodexChatStreamingUpdateLimiter
    ) async throws -> Bool {
        var eventsSinceYield = 0
        for try await event in stream {
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

    private func reconcileFromRollout(preservingReasoningFrom responseID: String) async {
        guard let backendThreadID,
              let thread = try? await service.loadThread(id: backendThreadID)
        else { return }
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

    private func finishGeneration() {
        isGenerating = false
        activeTurnID = nil
        isStopRequested = false
        unsubscribeIfPossible()
    }

    private static let maximumEventsBetweenYields = 64

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
        referenceIDsSnapshot: [UUID] = []
    ) {
        guard isBoundToCurrentVault,
              !isGenerating,
              text.nilIfBlank != nil else { return }
        isGenerating = true
        errorMessage = nil

        Task { [weak self] in
            await self?.resolveContextAndRunTurn(
                text: text,
                clearsDraft: clearsDraft,
                draftSnapshot: draftSnapshot ?? text,
                referenceIDsSnapshot: referenceIDsSnapshot
            )
        }
    }

    func resolveContextAndRunTurn(
        text: String,
        clearsDraft: Bool,
        draftSnapshot: String,
        referenceIDsSnapshot: [UUID]
    ) async {
        let context: CodexChatContext?
        do {
            guard let vaultID else { throw CodexAppServerError.invalidProtocolResponse }
            context = try await contextProvider.currentContext(vaultID: vaultID)
        } catch {
            lastSubmittedText = text
            errorMessage = error.localizedDescription
            finishGeneration()
            return
        }
        guard !isReleased,
              !isStopRequested,
              isBoundToCurrentVault else {
            finishGeneration()
            return
        }
        if clearsDraft {
            if draft == draftSnapshot {
                draft = ""
            }
            if selectedMeetingReferenceIDs == referenceIDsSnapshot {
                selectedMeetingReferenceIDs = []
            }
        }
        lastSubmittedText = text
        messages.append(CodexChatMessage(role: .user, text: text, context: context))
        let responseID = "pending-\(UUID.v7().uuidString)"
        messages.append(CodexChatMessage(id: responseID, role: .assistant, text: "", isStreaming: true))

        await runTurn(text: text, context: context, responseID: responseID)
    }
}

extension CodexChatSessionModel {
    var displayTitle: String {
        displayText(title.nilIfBlank ?? L10n.newChat)
    }

    var canSend: Bool {
        isBoundToCurrentVault
            && !isGenerating
            && (draft.nilIfBlank != nil || !selectedMeetingReferenceIDs.isEmpty)
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
