import SwiftUI

/// Plugins as cards, as the Connectors tab shows services: a card's switch installs or uninstalls it.
struct AgentPackageSettingsView: View {
    @Bindable var model: PiPackageSettingsModel
    @Environment(MainWindowNavigation.self) private var navigation

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField(L10n.agentPackageSource, text: $model.source, prompt: Text("npm:package / https://github.com/owner/repo"))
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isBusy)
                        .onSubmit { if model.canInstall { model.install() } }
                    Button(L10n.agentPackageInstall, action: model.install)
                        .disabled(!model.canInstall)
                    Link(destination: URL(string: "https://pi.dev/packages")!) {
                        Label(L10n.agentPackageCatalog, systemImage: "arrow.up.right.square")
                    }
                }
                Text(L10n.agentPackageHelp).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
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
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    autoReviewCard
                    ForEach(otherPackages, id: \.self) { source in
                        AgentMCPServiceCard(
                            name: PiPackageService.displayName(source),
                            comment: source,
                            icon: Image(systemName: "puzzlepiece.extension"),
                            isEnabled: Binding { true } set: { if !$0 { model.remove(source) } }
                        ) {
                            if model.changingSource == source { ProgressView().controlSize(.small) }
                        }
                        .help(source)
                    }
                }
                .disabled(model.isBusy)
                .padding(.top, 12)
            }
            .frame(maxWidth: 700)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .font(.dahliaBody)
        .task { await model.refresh() }
    }

    private var columns: [GridItem] {
        [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)]
    }

    private var otherPackages: [String] {
        model.packages.filter { !AgentAutoReviewSettings.isPackage($0) }
    }

    /// Recommended, so it shows switched off until installed.
    private var autoReviewCard: some View {
        let installedSource = model.packages.first(where: AgentAutoReviewSettings.isPackage)
        let source = installedSource ?? AgentAutoReviewSettings.packageSource
        return AgentMCPServiceCard(
            name: "pi-auto-review",
            comment: L10n.autoReviewPackageDescription,
            icon: Image(systemName: "checkmark.shield"),
            isEnabled: Binding { installedSource != nil } set: { installing in
                installing ? model.installAutoReview() : model.remove(source)
            }
        ) {
            if model.changingSource == source {
                ProgressView().controlSize(.small)
            } else if model.isAutoReviewInstalled {
                Button(L10n.autoReviewSettings, systemImage: "gearshape") {
                    navigation.presentSettingsModal(
                        AgentAutoReviewSettingsModal(account: model.account, onClose: navigation.dismissSettingsModal)
                    )
                }
                .labelStyle(.iconOnly)
                .help(L10n.autoReviewSettings)
                .buttonStyle(AgentMCPIconButtonStyle())
            }
        }
    }
}

/// The reviewer settings belong to the plugin, so its card opens them.
private struct AgentAutoReviewSettingsModal: View {
    let account: CodexRuntimeProvider
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Button(action: onClose) {
                Color.black.opacity(0.16).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Form { AgentAutoReviewSettingsSection(account: account) }
                    .formStyle(.grouped)
                HStack {
                    Spacer()
                    Button(L10n.close, action: onClose)
                        .buttonStyle(.dahlia())
                        .keyboardShortcut(.cancelAction)
                }
                .padding([.horizontal, .bottom], 20)
            }
            .frame(width: 560, height: 360)
            .dahliaModalSurface()
        }
        .font(.dahliaBody)
        .transition(.identity)
    }
}
