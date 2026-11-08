import SwiftUI

/// Chat agent settings: the Pi command the open account runs, models, and the open account's MCPs.
struct AgentSettingsView: View {
    @State private var workspaceSettings = WorkspaceAISettingsModel.shared

    var body: some View {
        let provider = CodexRuntimeProvider(
            accountConnectionID: workspaceSettings.accountConnectionID,
            databricksConnectionID: workspaceSettings.databricksAccountConnectionID
        )
        TabView {
            Form { AgentGeneralSettingsView(provider: provider).id(provider) }
                .formStyle(.grouped)
                .tabItem { Text(L10n.general) }
            // shortcut: placeholder until agent model settings are designed.
            Form {
                Section { Text(L10n.agentModelsPlaceholder).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            .tabItem { Text(L10n.agentModels) }
            Form { AgentMCPSettingsView() }
                .formStyle(.grouped)
                .tabItem { Text(L10n.agentMCPs) }
        }
    }
}

/// The Pi path belongs to the account; the Pi that Dahlia installs is shared by every account on this Mac.
private struct AgentGeneralSettingsView: View {
    let provider: CodexRuntimeProvider
    @AppStorage private var piPath: String
    @State private var resolvedCommand: Result<String, CodexAppServerError>?
    /// The version of the Pi that Dahlia installed, and whether this account runs it.
    @State private var installedVersion: String?
    @State private var usesInstalledPi = false
    @State private var isInstalling = false
    @State private var installResult: Result<String, Error>?

    init(provider: CodexRuntimeProvider) {
        self.provider = provider
        _piPath = AppStorage(wrappedValue: "", PiBundle.executablePathDefaultsKey(for: provider))
    }

    var body: some View {
        Section {
            TextField(L10n.piCommand, text: $piPath, prompt: Text(L10n.piCommandAutomatic))
            LabeledContent(L10n.piCommandInUse) {
                switch resolvedCommand {
                case let .success(path):
                    Text(path).textSelection(.enabled)
                case let .failure(error):
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case nil:
                    EmptyView()
                }
            }
            // Installing helps users without a pi of their own; the installed Pi is used only once chosen as the path.
            if let installedVersion {
                LabeledContent(L10n.piInstalledVersion(installedVersion)) {
                    if isInstalling {
                        ProgressView().controlSize(.small)
                    } else if usesInstalledPi {
                        Button(L10n.updatePi) { startInstall() }
                    } else {
                        Button(L10n.useInstalledPi) { piPath = PiInstaller.executableURL.path }
                    }
                }
            } else if case .failure = resolvedCommand {
                LabeledContent(L10n.piNotInstalled) {
                    if isInstalling {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L10n.installPi) { startInstall() }
                    }
                }
            }
            switch installResult {
            case let .success(message):
                Text(message).foregroundStyle(.secondary)
            case let .failure(error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case nil:
                EmptyView()
            }
        } footer: {
            Text(L10n.piCommandDescription)
        }
        .task(id: piPath) {
            await resolveCommand()
        }
    }

    /// Resolving checks the disk, so it runs off MainActor; Pi reads the saved path when each process starts.
    private func resolveCommand() async {
        let (resolved, version, usesInstalled) = await Task.detached { [provider] in
            let url = Result { try PiBundle.executableURL(for: provider) }
                .mapError { $0 as? CodexAppServerError ?? .piCommandNotFound(nil) }
            // A link on PATH to the Pi that Dahlia installed, as the README suggests, still counts as that Pi.
            let usesInstalled = (try? url.get().resolvingSymlinksInPath()) == PiInstaller.executableURL.resolvingSymlinksInPath()
            return (url.map(\.path), PiInstaller.installedVersion(), usesInstalled)
        }.value
        // An edit cancels this task, but the detached lookup still finishes; drop its now-stale result.
        guard !Task.isCancelled else { return }
        resolvedCommand = resolved
        installedVersion = version
        usesInstalledPi = usesInstalled
    }

    private func startInstall() {
        // Set before the task starts so a second click cannot start another install.
        isInstalling = true
        Task { await installLatestPi() }
    }

    private func installLatestPi() async {
        installResult = nil
        do {
            let release = try await PiInstaller.release()
            if release.version == installedVersion {
                installResult = .success(L10n.piUpToDate(release.version))
            } else {
                let isFirstInstall = installedVersion == nil
                try await PiInstaller.install(release)
                installResult = .success(L10n.piInstalled(release.version))
                // Install is offered only when this account has no working pi, so it takes the one it asked for.
                if isFirstInstall { piPath = PiInstaller.executableURL.path }
            }
        } catch {
            installResult = .failure(error)
        }
        isInstalling = false
        await resolveCommand()
    }
}

/// MCPs grouped by where they come from; only Unity Gateway exists today.
private struct AgentMCPSettingsView: View {
    @State private var workspaceSettings = WorkspaceAISettingsModel.shared

    var body: some View {
        if workspaceSettings.isDatabricksAccount, let connectionID = workspaceSettings.databricksAccountConnectionID {
            Section {
                ForEach(DatabricksGatewayMCP.allCases) { mcp in
                    GatewayMCPToggle(mcp: mcp, connectionID: connectionID)
                }
            } header: {
                Text(L10n.unityGateway)
            } footer: {
                Text(L10n.unityGatewayMCPsDescription)
            }
            .id(connectionID)
        } else {
            Section {
                Text(L10n.agentMCPsRequireDatabricks).foregroundStyle(.secondary)
            } header: {
                Text(L10n.unityGateway)
            }
        }
    }
}

private struct GatewayMCPToggle: View {
    let mcp: DatabricksGatewayMCP
    @AppStorage private var isOn: Bool

    init(mcp: DatabricksGatewayMCP, connectionID: UUID) {
        self.mcp = mcp
        _isOn = AppStorage(wrappedValue: false, mcp.defaultsKey(connectionID: connectionID))
    }

    var body: some View {
        // Chat processes started after a change use the new servers; one already open keeps its own until it closes.
        Toggle(mcp.displayName, isOn: $isOn)
            .toggleStyle(.switch)
    }
}
