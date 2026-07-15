import Foundation
import Observation

@MainActor
@Observable
final class CodexChatSessionModel: Identifiable {
    let id: CodexChatSessionID
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

    @ObservationIgnored private let service: any CodexChatServicing
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var isStopRequested = false
    @ObservationIgnored private var isReleased = false
    @ObservationIgnored private var didUnsubscribe = false

    init(
        id: CodexChatSessionID = CodexChatSessionID(),
        backendThreadID: String? = nil,
        title: String = "",
        messages: [CodexChatMessage] = [],
        modelID: String? = nil,
        effort: String? = nil,
        service: any CodexChatServicing = CodexChatService.shared,
        settings: AppSettings = .shared
    ) {
        self.id = id
        self.backendThreadID = backendThreadID
        self.title = title
        self.messages = messages
        self.selectedModelID = modelID ?? settings.codexChatModelID
        self.selectedEffort = effort ?? settings.codexChatReasoningEffort
        self.service = service
        self.settings = settings
    }

    var displayTitle: String {
        title.nilIfBlank ?? L10n.newChat
    }

    var canSend: Bool {
        !isGenerating && draft.nilIfBlank != nil
    }

    var effortOptions: [CodexReasoningEffortOption] {
        guard let model = models.first(where: { $0.model == selectedModelID }) else { return [] }
        return model.supportedReasoningEfforts.isEmpty
            ? [CodexReasoningEffortOption(reasoningEffort: model.defaultReasoningEffort, description: "")]
            : model.supportedReasoningEfforts
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
            async let restoredThread = service.resumeThread(id: backendThreadID)
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
        guard let text = draft.nilIfBlank else { return }
        draft = ""
        send(text)
    }

    func retry() {
        guard let lastSubmittedText else { return }
        send(lastSubmittedText)
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
        unsubscribeIfPossible()
    }

    private func send(_ text: String) {
        guard !isGenerating, text.nilIfBlank != nil else { return }
        isGenerating = true
        errorMessage = nil
        lastSubmittedText = text
        messages.append(CodexChatMessage(role: .user, text: text))
        let responseID = "pending-\(UUID.v7().uuidString)"
        messages.append(CodexChatMessage(id: responseID, role: .assistant, text: "", isStreaming: true))

        Task { [weak self] in
            await self?.runTurn(text: text, responseID: responseID)
        }
    }

    private func runTurn(text: String, responseID: String) async {
        var responseIDsByItemID: [String: String] = [:]
        do {
            if models.isEmpty {
                await prepare()
            }
            try Task.checkCancellation()
            if backendThreadID == nil {
                let thread = try await service.startThread(
                    model: selectedModelID.nilIfBlank,
                    effort: selectedEffort
                )
                apply(thread, preservingPendingMessages: true)
            }
            guard let backendThreadID else {
                throw CodexAppServerError.invalidProtocolResponse
            }

            let stream = try await service.send(
                threadID: backendThreadID,
                text: text,
                model: selectedModelID.nilIfBlank,
                effort: selectedEffort
            )
            var turnCompleted = false
            for try await event in stream {
                apply(event, responseID: responseID, responseIDsByItemID: &responseIDsByItemID)
                if case .completed(itemID: nil, text: nil) = event {
                    turnCompleted = true
                }
            }
            if turnCompleted {
                await reconcileFromRollout()
            }
        } catch is CancellationError {
            completeTurnResponses(responseID: responseID, responseIDsByItemID: responseIDsByItemID)
        } catch {
            errorMessage = error.localizedDescription
            completeTurnResponses(responseID: responseID, responseIDsByItemID: responseIDsByItemID)
        }
        finishGeneration()
    }

    private func apply(
        _ event: CodexChatTurnEvent,
        responseID: String,
        responseIDsByItemID: inout [String: String]
    ) {
        switch event {
        case let .started(turnID):
            activeTurnID = turnID
            if isStopRequested, let backendThreadID {
                Task { await service.interrupt(threadID: backendThreadID, turnID: turnID) }
            }
        case let .delta(itemID, text):
            let messageID = responseMessageID(
                for: itemID,
                pendingResponseID: responseID,
                responseIDsByItemID: &responseIDsByItemID
            )
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
            messages[index].text += text
        case let .completed(itemID?, text):
            let messageID = responseMessageID(
                for: itemID,
                pendingResponseID: responseID,
                responseIDsByItemID: &responseIDsByItemID
            )
            if let text, let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index].text = text
                messages[index].isStreaming = false
            }
        case .completed(itemID: nil, text: _):
            completeTurnResponses(responseID: responseID, responseIDsByItemID: responseIDsByItemID)
        case .interrupted:
            completeTurnResponses(responseID: responseID, responseIDsByItemID: responseIDsByItemID)
        case let .failed(message):
            errorMessage = CodexAppServerError.turnFailed(message).localizedDescription
            completeTurnResponses(responseID: responseID, responseIDsByItemID: responseIDsByItemID)
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

    private func markResponseComplete(id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].isStreaming = false
    }

    private func responseMessageID(
        for itemID: String,
        pendingResponseID: String,
        responseIDsByItemID: inout [String: String]
    ) -> String {
        if let existingID = responseIDsByItemID[itemID] {
            return existingID
        }

        if responseIDsByItemID.isEmpty {
            responseIDsByItemID[itemID] = pendingResponseID
            return pendingResponseID
        }

        let messageID = "response-\(itemID)"
        responseIDsByItemID[itemID] = messageID
        messages.append(CodexChatMessage(id: messageID, role: .assistant, text: "", isStreaming: true))
        return messageID
    }

    private func completeTurnResponses(
        responseID: String,
        responseIDsByItemID: [String: String]
    ) {
        markResponseComplete(id: responseID)
        for messageID in responseIDsByItemID.values where messageID != responseID {
            markResponseComplete(id: messageID)
        }
        messages.removeAll { $0.id == responseID && $0.text.isEmpty }
    }

    private func reconcileFromRollout() async {
        guard let backendThreadID,
              let thread = try? await service.loadThread(id: backendThreadID)
        else { return }
        apply(thread, preservingPendingMessages: thread.messages.count < messages.count)
    }

    private func finishGeneration() {
        isGenerating = false
        activeTurnID = nil
        isStopRequested = false
        unsubscribeIfPossible()
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
