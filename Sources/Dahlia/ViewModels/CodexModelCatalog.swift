import Foundation
import Observation

@MainActor
@Observable
final class CodexModelCatalog {
    private(set) var models: [CodexModel] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let service: CodexAppServerService

    init(service: CodexAppServerService = .shared) {
        self.service = service
    }

    func load(forceRefresh: Bool = false) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            models = try await service.models(forceRefresh: forceRefresh)
            if models.isEmpty {
                errorMessage = L10n.codexNoModels
            }
        } catch is CancellationError {
            errorMessage = nil
        } catch {
            models = []
            errorMessage = error.localizedDescription
        }
    }

    func resolvedSelection(current: String) -> String? {
        let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if models.contains(where: { $0.model == current }) {
            return current
        }
        return models.first(where: \CodexModel.isDefault)?.model ?? models.first?.model
    }

    func selectionToPersist(current: String) -> String? {
        guard current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return resolvedSelection(current: current)
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
