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
                    webAccessCard
                    mcpElicitationCard
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
        model.packages.filter {
            !AgentAutoReviewSettings.isPackage($0) && !AgentWebAccessSettings.isPackage($0)
        }
    }

    /// Bundled with Dahlia, so its switch stays on.
    private var autoReviewCard: some View {
        AgentMCPServiceCard(
            name: "pi-auto-review", comment: L10n.autoReviewPackageDescription, icon: Image(systemName: "checkmark.shield"),
            isEnabled: .constant(true), isLocked: true
        ) {
            Button(L10n.autoReviewSettings, systemImage: "gearshape") {
                navigation.presentSettingsModal(
                    AgentPluginSettingsModal(height: 360, onClose: navigation.dismissSettingsModal) {
                        Form { AgentAutoReviewSettingsSection() }
                            .formStyle(.grouped)
                    } actions: {
                        Button(L10n.close, action: navigation.dismissSettingsModal)
                            .buttonStyle(.dahlia())
                            .keyboardShortcut(.cancelAction)
                    }
                )
            }
            .labelStyle(.iconOnly)
            .help(L10n.autoReviewSettings)
            .buttonStyle(AgentMCPIconButtonStyle())
        }
    }

    private var webAccessCard: some View {
        recommendedCard(
            name: "pi-web-access", comment: L10n.webAccessPackageDescription, systemImage: "globe",
            packageSource: AgentWebAccessSettings.packageSource, isPackage: AgentWebAccessSettings.isPackage,
            isInstalled: model.isWebAccessInstalled, install: model.installWebAccess, settingsTitle: L10n.webAccessSettings
        ) {
            AgentWebAccessSettingsModal(onClose: navigation.dismissSettingsModal)
        }
    }

    /// Bundled with Dahlia and always loaded, so it shows switched on and cannot be turned off.
    private var mcpElicitationCard: some View {
        AgentMCPServiceCard(
            name: AgentMCPElicitationSettings.packageName,
            comment: L10n.mcpElicitationPackageDescription,
            icon: Image(systemName: "person.badge.key"),
            isEnabled: .constant(true),
            isLocked: true
        ) {}
            .help(L10n.mcpElicitationBuiltIn)
    }

    /// Recommended, so it shows switched off until installed; its settings open once its files are in place.
    private func recommendedCard(
        name: String,
        comment: String,
        systemImage: String,
        packageSource: String,
        isPackage: (String) -> Bool,
        isInstalled: Bool,
        install: @escaping () -> Void,
        settingsTitle: String,
        settings: @escaping () -> some View
    ) -> some View {
        let installedSource = model.packages.first(where: isPackage)
        let source = installedSource ?? packageSource
        return AgentMCPServiceCard(
            name: name,
            comment: comment,
            icon: Image(systemName: systemImage),
            isEnabled: Binding { installedSource != nil } set: { installing in
                installing ? install() : model.remove(source)
            }
        ) {
            if model.changingSource == source {
                ProgressView().controlSize(.small)
            } else if isInstalled {
                Button(settingsTitle, systemImage: "gearshape") {
                    navigation.presentSettingsModal(settings())
                }
                .labelStyle(.iconOnly)
                .help(settingsTitle)
                .buttonStyle(AgentMCPIconButtonStyle())
            }
        }
    }
}

/// A plugin's settings belong to it, so its card opens them; the backdrop does what the first action cancels.
struct AgentPluginSettingsModal<Content: View, Actions: View>: View {
    let height: CGFloat
    var isSaving = false
    let onClose: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        ZStack {
            Button(action: onClose) {
                Color.black.opacity(0.16).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)
            .disabled(isSaving)

            VStack(alignment: .leading, spacing: 0) {
                content
                HStack {
                    Spacer()
                    actions
                }
                .padding([.horizontal, .bottom], 20)
            }
            .frame(width: 560, height: height)
            .dahliaModalSurface()
        }
        .font(.dahliaBody)
        .transition(.identity)
    }
}

/// Edits the plugin's `web-search.json`; Save writes it, and the next chat reads it.
private struct AgentWebAccessSettingsModal: View {
    let onClose: () -> Void
    @State private var configuration: AgentWebAccessSettings.Configuration?
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        AgentPluginSettingsModal(height: 560, isSaving: isSaving, onClose: onClose) {
            Form {
                Section {
                    LabeledContent {
                        Toggle(
                            L10n.webAccessWebSearch,
                            isOn: Binding { configuration?.webSearchEnabled ?? false } set: { configuration?.webSearchEnabled = $0 }
                        )
                        .labelsHidden()
                        .toggleStyle(.dahliaSwitch)
                    } label: {
                        HStack {
                            Text(L10n.webAccessWebSearch)
                            SettingsInfoButton(help: L10n.webAccessWebSearchHelp)
                        }
                    }
                } header: {
                    Text(L10n.webAccessSettings).font(.dahliaSectionHeader)
                }
                Section {
                    ForEach(AgentWebAccessSettings.apiKeys, id: \.key) { entry in
                        LabeledContent(entry.provider) {
                            SecureField(
                                entry.provider,
                                text: Binding { configuration?.apiKeys[entry.key] ?? "" } set: { configuration?.apiKeys[entry.key] = $0 },
                                prompt: Text(L10n.webAccessAPIKeyPrompt)
                            )
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                } header: {
                    Text(L10n.webAccessAPIKeys).font(.dahliaSectionHeader)
                } footer: {
                    Text(L10n.webAccessAPIKeysHelp).font(.dahliaSecondary).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    SettingsStatusMessage(text: errorMessage, systemImage: "exclamationmark.triangle", tint: .orange)
                }
            }
            .formStyle(.grouped)
            .disabled(configuration == nil || isSaving)
        } actions: {
            Button(L10n.cancel, action: onClose)
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button(L10n.save, action: save)
                .buttonStyle(.dahlia())
                .keyboardShortcut(.defaultAction)
                .disabled(configuration == nil || isSaving)
        }
        .task {
            do {
                configuration = try await PiPackageService.shared.webAccessConfiguration()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let configuration else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await PiPackageService.shared.saveWebAccessConfiguration(configuration)
                onClose()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
