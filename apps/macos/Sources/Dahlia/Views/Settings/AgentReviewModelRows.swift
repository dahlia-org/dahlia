import SwiftUI

/// Independent model and reasoning settings for memory or skill reviews.
struct AgentReviewModelRows: View {
    let kind: AgentLearningSettings.ReviewKind
    let models: [CodexModel]
    @AppStorage private var model: String
    @AppStorage private var effort: String

    init(kind: AgentLearningSettings.ReviewKind, models: [CodexModel]) {
        self.kind = kind
        self.models = models
        _model = AppStorage(
            wrappedValue: AgentLearningSettings.reviewModel(AppAccount.key, kind: kind),
            AgentLearningSettings.reviewModelKey(AppAccount.key, kind: kind)
        )
        _effort = AppStorage(
            wrappedValue: AgentLearningSettings.reviewEffort(AppAccount.key, kind: kind),
            AgentLearningSettings.reviewEffortKey(AppAccount.key, kind: kind)
        )
    }

    var body: some View {
        LabeledContent {
            Picker(L10n.agentReviewModel, selection: $model) {
                if model.isEmpty { Text(L10n.agentReviewModelSelect).font(.dahliaBody).tag("") }
                if !model.isEmpty, !models.contains(where: { $0.model == model }) {
                    Text(model).font(.dahliaBody).tag(model)
                }
                ForEach(models) { Text($0.displayName).font(.dahliaBody).tag($0.model) }
            }
            .labelsHidden()
        } label: {
            HStack {
                Text(L10n.agentReviewModel)
                SettingsInfoButton(help: L10n.agentReviewModelHelp)
            }
        }
        .onChange(of: models, initial: true) {
            if let selected = AgentLearningSettings.prepareReviewModel(AppAccount.key, kind: kind, models: models) { model = selected }
        }
        LabeledContent(L10n.agentReviewEffort) {
            Picker(L10n.agentReviewEffort, selection: $effort) {
                ForEach(models.reasoningEfforts(for: model, keeping: effort)) { option in
                    Text(option.displayName).font(.dahliaBody).tag(option.reasoningEffort)
                }
            }
            .labelsHidden()
        }
    }
}

extension [CodexModel] {
    /// The selected model's levels; with the automatic model, every level a listed model offers. A saved level that no
    /// listed model offers stays selectable instead of silently changing.
    func reasoningEfforts(for model: String, keeping current: String) -> [CodexReasoningEffortOption] {
        let options = first(where: { $0.model == model })?.supportedReasoningEfforts ?? flatMap(\.supportedReasoningEfforts)
        var seen: Set<String> = []
        let unique = options.filter { seen.insert($0.reasoningEffort).inserted }
        return unique.contains(where: { $0.reasoningEffort == current }) || current.isEmpty
            ? unique : unique + [CodexReasoningEffortOption(reasoningEffort: current, description: "")]
    }
}
