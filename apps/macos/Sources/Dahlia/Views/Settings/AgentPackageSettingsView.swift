import SwiftUI

struct AgentPackageSettingsView: View {
    @Bindable var model: PiPackageSettingsModel

    var body: some View {
        Form {
            Section {
                Link(destination: URL(string: "https://pi.dev/packages")!) {
                    Label(L10n.agentPackageCatalog, systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                TextField(L10n.agentPackageSource, text: $model.source, prompt: Text("npm:package / https://github.com/owner/repo"))
                    .disabled(model.isBusy)
                    .onSubmit { if model.canInstall { model.install() } }
                HStack {
                    Button(L10n.agentPackageInstall, action: model.install)
                        .disabled(!model.canInstall)
                    if model.isBusy { ProgressView().controlSize(.small) }
                }
                if let message = model.errorMessage {
                    Text(message).foregroundStyle(.red).textSelection(.enabled)
                }
                if let details = model.errorDetails {
                    DisclosureGroup(L10n.agentPackageErrorDetails) {
                        Text(details)
                            .font(.dahliaSecondary)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if model.didChange {
                    Text(L10n.agentPackageChanged).foregroundStyle(.secondary)
                }
            } header: {
                Text(L10n.agentPackages).font(.dahliaSectionHeader)
            } footer: {
                Text(L10n.agentPackageHelp)
            }
            Section {
                if model.packages.isEmpty {
                    Text(L10n.agentPackagesEmpty).foregroundStyle(.secondary)
                }
                ForEach(model.packages, id: \.self) { source in
                    LabeledContent {
                        Button(L10n.agentPackageRemove) { model.remove(source) }
                            .disabled(model.isBusy)
                    } label: {
                        Text(source).textSelection(.enabled)
                    }
                }
            } header: {
                Text(L10n.agentPackagesInstalled).font(.dahliaSectionHeader)
            }
        }
        .formStyle(.grouped)
        .font(.dahliaBody)
        .task { await model.refresh() }
    }
}
