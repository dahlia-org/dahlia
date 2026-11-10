import SwiftUI

/// The chat's models, grouped under their providers in the order Pi lists them.
struct CodexChatModelPickerPanel: View {
    @Bindable var session: CodexChatSessionModel
    let height: CGFloat

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CodexChatDesign.configurationRowSpacing) {
                Text(L10n.model)
                    .font(.body)
                    .foregroundStyle(DahliaDesign.optionalTextColor)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)

                ForEach(groups, id: \.providerID) { group in
                    Text(title(of: group.providerID))
                        .font(.caption)
                        .foregroundStyle(DahliaDesign.optionalTextColor)
                        .lineLimit(1)
                        // The workspace name leads the host, so the cloud domain is what gets cut.
                        .truncationMode(.tail)
                        .padding(.horizontal, 10)
                        .padding(.top, 4)

                    ForEach(group.models) { model in
                        CodexChatConfigurationRow(
                            title: name(of: model, in: group.providerID),
                            isSelected: model.model == session.selectedModelID,
                            action: { session.selectModel(model.model) }
                        )
                    }
                }
            }
            .padding(10)
        }
        .scrollIndicators(.hidden)
        .frame(
            width: CodexChatDesign.modelPanelWidth,
            height: height
        )
    }

    private var groups: [(providerID: String, models: [CodexModel])] {
        let sorted = session.models.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let providerIDs = session.models.map(providerID).reduce(into: [String]()) { ids, id in
            if !ids.contains(id) { ids.append(id) }
        }
        return providerIDs.map { id in (id, sorted.filter { providerID(of: $0) == id }) }
    }

    private func providerID(of model: CodexModel) -> String {
        String(model.model.prefix { $0 != "/" })
    }

    private func title(of providerID: String) -> String {
        if let subscription = PiSubscription(rawValue: providerID) { return subscription.displayName }
        if providerID == "dahlia" { return L10n.dahliaAccount }
        guard providerID == PiProviderConfiguration.databricksProviderIDs[0] else { return L10n.unityGatewayHost(providerID) }
        // The Databricks account's own gateway.
        let settings = WorkspaceAISettingsModel.shared
        let host = settings.databricksConnections.first { $0.id == settings.databricksAccountConnectionID }?.hostName
        return host.map(L10n.unityGatewayHost) ?? L10n.databricksUnityGateway
    }

    /// The group already names the workspace, which a workspace's model names carry for flat lists.
    private func name(of model: CodexModel, in providerID: String) -> String {
        guard PiProviderConfiguration.isAddedWorkspace(providerID), let label = providerID.split(separator: ".").first else {
            return model.displayName
        }
        let suffix = " (\(label))"
        return model.displayName.hasSuffix(suffix) ? String(model.displayName.dropLast(suffix.count)) : model.displayName
    }
}
