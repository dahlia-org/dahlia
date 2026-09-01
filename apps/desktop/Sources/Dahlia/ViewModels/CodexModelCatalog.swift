import Foundation
import Observation

@MainActor
@Observable
final class CodexModelCatalog {
    private(set) var models: [CodexModel] = []
    private(set) var isLoading = false
    private(set) var hasAttemptedLoad = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var loadGeneration = 0

    private let service: CodexAppServerService

    init(service: CodexAppServerService = .shared) {
        self.service = service
    }

    func load(forceRefresh: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        hasAttemptedLoad = true
        isLoading = true
        errorMessage = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }

        do {
            let loadedModels = try await service.models(forceRefresh: forceRefresh)
            guard loadGeneration == generation, !Task.isCancelled else { return }
            models = loadedModels
            if models.isEmpty {
                errorMessage = L10n.codexNoModels
            }
        } catch is CancellationError {
            if loadGeneration == generation {
                errorMessage = nil
            }
        } catch {
            guard loadGeneration == generation else { return }
            models = []
            errorMessage = error.localizedDescription
        }
    }

    var canRetry: Bool {
        hasAttemptedLoad && models.isEmpty
    }

    func resolvedSelection(current: String) -> String? {
        let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if models.contains(where: { $0.model == current }) {
            return current
        }
        return models.first(where: \CodexModel.isDefault)?.model ?? models.first?.model
    }

    func selectionToPersist(current: String) -> String? {
        let resolved = resolvedSelection(current: current)
        return resolved == current.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : resolved
    }

    func effortOptions(modelID: String) -> [CodexReasoningEffortOption] {
        guard let model = resolvedModel(modelID: modelID) else { return [] }
        if !model.supportedReasoningEfforts.isEmpty {
            return model.supportedReasoningEfforts
        }
        return [
            CodexReasoningEffortOption(
                reasoningEffort: model.defaultReasoningEffort,
                description: ""
            ),
        ]
    }

    func resolvedEffort(current: String, modelID: String) -> String? {
        guard models.contains(where: { $0.model == modelID }) else { return nil }
        let options = effortOptions(modelID: modelID)
        guard !options.isEmpty else { return nil }
        let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if options.contains(where: { $0.reasoningEffort == current }) {
            return current
        }
        if options.contains(where: { $0.reasoningEffort == CodexReasoningEffortOption.defaultValue }) {
            return CodexReasoningEffortOption.defaultValue
        }
        if let modelDefault = resolvedModel(modelID: modelID)?.defaultReasoningEffort,
           options.contains(where: { $0.reasoningEffort == modelDefault }) {
            return modelDefault
        }
        return options.first?.reasoningEffort
    }

    private func resolvedModel(modelID: String) -> CodexModel? {
        models.first(where: { $0.model == modelID })
            ?? models.first(where: \CodexModel.isDefault)
            ?? models.first
    }
}
