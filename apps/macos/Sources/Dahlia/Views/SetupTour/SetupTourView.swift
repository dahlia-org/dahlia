import SwiftUI

struct SetupTourView: View {
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation
    @ObservedObject private var settings = AppSettings.shared
    @State private var model: SetupTourModel
    @State private var accountController: DahliaCloudAccountController
    @State private var isLanguageMenuHovered = false
    @State private var isCloseHovered = false

    private let workspaceManagementModel: WorkspaceManagementModel
    private let canComplete: () -> Bool
    private let onComplete: (WorkspaceRecord, UUID?) async -> Bool
    private let stepReferenceHeight: CGFloat = 476

    init(
        mode: SetupTourMode,
        currentWorkspace: WorkspaceRecord?,
        workspaceManagementModel: WorkspaceManagementModel,
        accountController: DahliaCloudAccountController,
        canComplete: @escaping () -> Bool,
        onComplete: @escaping (WorkspaceRecord, UUID?) async -> Bool
    ) {
        self.workspaceManagementModel = workspaceManagementModel
        self.canComplete = canComplete
        self.onComplete = onComplete
        _accountController = State(initialValue: accountController)
        let initialWorkspace = mode == .initial ? currentWorkspace : currentWorkspace ?? workspaceManagementModel.workspaces.first
        _model = State(initialValue: SetupTourModel(
            mode: mode,
            currentWorkspace: initialWorkspace,
            signedInAccountConnectionIDs: Set(accountController.connections.filter(\.isSignedIn).map(\.id)),
            progressDefaults: .standard
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            DahliaWindowHeader(reservesWindowControls: true) {
                Text(L10n.setupDahlia)
                    .font(.headline)

                // Account-scoped settings, such as model providers and calendars, apply to this account.
                if model.currentStep != .account, model.isAccountSelectionConfirmed {
                    Label {
                        Text(selectedAccountTitle)
                    } icon: {
                        selectedAccountIcon
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(L10n.account), \(selectedAccountTitle)")
                }

                Spacer()
            }

            GeometryReader { proxy in
                ZStack(alignment: .topTrailing) {
                    ScrollView {
                        VStack(spacing: 28) {
                            if model.currentStep != .account {
                                SetupTourStepHeaderView(step: model.currentStep)
                            }

                            stepContent
                                .frame(maxWidth: 900)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 40)
                        .padding(.top, max((proxy.size.height - stepReferenceHeight) / 2, 32))
                        .padding(.bottom, 32)
                    }

                    HStack(spacing: DahliaDesign.windowHeaderGroupSpacing) {
                        Menu {
                            ForEach(AppLanguage.allCases) { language in
                                Button {
                                    settings.appLanguage = language
                                } label: {
                                    if settings.appLanguage == language {
                                        Label(language.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(language.displayName)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "globe")
                                Text(settings.appLanguage.displayName)
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                            }
                            .font(.callout)
                            .padding(.horizontal, 9)
                            .frame(minHeight: DahliaDesign.windowHeaderControlSize)
                            .contentShape(.rect)
                            .background(
                                isLanguageMenuHovered ? DahliaDesign.contentHighlightColor : .clear,
                                in: .rect(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
                            )
                        }
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .onHover { isLanguageMenuHovered = $0 }
                        .accessibilityLabel(L10n.appLanguage)
                        .accessibilityValue(settings.appLanguage.displayName)

                        if model.mode == .manual {
                            Button(action: dismissTour) {
                                Label(L10n.close, systemImage: "xmark")
                                    .labelStyle(.iconOnly)
                                    .font(.body)
                                    .frame(
                                        width: DahliaDesign.windowHeaderControlSize,
                                        height: DahliaDesign.windowHeaderControlSize
                                    )
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .background(
                                isCloseHovered ? DahliaDesign.contentHighlightColor : .clear,
                                in: .rect(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
                            )
                            .onHover { isCloseHovered = $0 }
                            .accessibilityLabel(L10n.close)
                            .disabled(model.isCompleting)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 16)
                }
            }

            SetupTourActionBarView(
                step: model.currentStep,
                steps: model.visibleSteps,
                canGoBack: model.canGoBack,
                canContinue: canContinue,
                isCompleting: model.isCompleting,
                onBack: model.goBack,
                onContinue: continueTour
            )
        }
        .task(id: model.isAccountSelectionConfirmed
            ? model.selectedAccountConnectionID?.uuidString ?? model.selectedDatabricksConnectionID.map { "databricks.\($0)" } ?? "local"
            : nil) {
                guard model.mode == .initial, model.isAccountSelectionConfirmed else { return }
                _ = await prepareInitialWorkspace()
        }
        .id(settings.appLanguage)
        // Outside `.id`, so a language change does not clear the account mid-tour.
        .onChange(of: tourAccount, initial: true) { _, account in settings.setupTourAccount = account }
        .onDisappear { settings.setupTourAccount = nil }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .windowDismissBehavior(
            model.mode == .initial || model.isCompleting || accountController.isBusy ? .disabled : .automatic
        )
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.currentStep {
        case .account:
            // Dahlia Cloud and Server sign-in are hidden for now; existing connections stay usable from Settings.
            DatabricksSignInView(
                isEmbedded: true,
                onCancel: {},
                onContinueWithDatabricks: continueWithDatabricks,
                onContinueLocally: continueWithLocalAccount
            )
        case .workingLanguages:
            WorkingLanguagesSetupStepView()
        case .permissions:
            PermissionSetupStepView()
        case .modelProvider:
            ModelProviderSetupStepView()
        case .calendar:
            CalendarSettingsView(showsOnlySourceSetup: true)
                .frame(height: 480)
        case .completion:
            SetupCompletionStepView(
                model: model,
                onReviewPermissions: { model.returnToStep(.permissions) },
                onRetry: completeTour
            )
        }
    }

    private func continueTour() {
        if model.currentStep == .completion {
            completeTour()
        } else {
            model.advance()
        }
    }

    private var tourAccount: CodexRuntimeProvider {
        CodexRuntimeProvider(
            accountConnectionID: model.selectedAccountConnectionID,
            databricksConnectionID: model.selectedDatabricksConnectionID
        )
    }

    private func continueWithLocalAccount() {
        model.selectAccountConnection(nil)
        model.advance()
    }

    private func continueWithDatabricks(_ connectionID: UUID) {
        model.selectAccountConnection(nil, databricks: connectionID)
        model.advance()
    }

    private var canContinue: Bool {
        guard model.canContinue else { return false }
        guard model.currentStep != .account || !accountController.isBusy else { return false }
        guard model.currentStep == .workingLanguages,
              settings.appLanguageScope == .selected else { return true }
        return !settings.enabledLanguageIdentifiers.isEmpty
    }

    private func dismissTour() {
        accountController.cancelAccountTask()
        mainWindowNavigation.dismissSetupTour()
    }

    private func prepareInitialWorkspace() async -> WorkspaceRecord? {
        let connectionID = model.selectedAccountConnectionID
        if let databricks = model.selectedDatabricksConnectionID {
            return await model.prepareInitialWorkspace {
                await WorkspaceAISettingsModel.shared.accountWorkspace(databricksConnectionID: databricks)
            }
        }
        return await model.prepareInitialWorkspace {
            let workspace = await workspaceManagementModel.resolveInitialWorkspace(accountConnectionID: connectionID) {
                guard let syncWorker = accountController.syncWorker else { throw DahliaCloudError.notConfigured }
                try await syncWorker.discoverCloudWorkspaces()
            }
            if workspace == nil { workspaceManagementModel.isShowingError = false }
            return workspace
        }
    }

    private func completeTour() {
        guard !model.isCompleting else { return }
        guard !requiresWorkspaceSwitch || canComplete() else {
            model.finishCompletion(errorMessage: L10n.workspaceOperationFailed)
            return
        }
        model.beginCompletion()
        Task {
            guard !requiresWorkspaceSwitch || canComplete() else {
                model.finishCompletion(errorMessage: L10n.workspaceOperationFailed)
                return
            }
            // The account's Default workspace is created automatically, so the tour does not ask for one.
            let workspace: WorkspaceRecord? = if model.mode == .initial {
                await prepareInitialWorkspace()
            } else if let originalWorkspace = model.originalWorkspace, model.keepsOriginalWorkspace {
                originalWorkspace
            } else {
                // The account step offers only the Local and Databricks accounts, so another account is one of them.
                await WorkspaceAISettingsModel.shared.accountWorkspace(databricksConnectionID: model.selectedDatabricksConnectionID)
            }
            guard let workspace else {
                workspaceManagementModel.isShowingError = false
                model.finishCompletion(
                    errorMessage: model.mode == .initial ? L10n.setupWorkspaceUnavailable : L10n.workspaceOperationFailed
                )
                return
            }
            guard await onComplete(workspace, model.selectedAccountConnectionID) else {
                model.finishCompletion(errorMessage: L10n.workspaceOperationFailed)
                return
            }
            model.finishCompletion(errorMessage: nil)
        }
    }

    private var requiresWorkspaceSwitch: Bool {
        !model.keepsOriginalWorkspace
    }

    private var selectedAccountTitle: String {
        if let connectionID = model.selectedAccountConnectionID {
            return accountController.connections.first { $0.id == connectionID }?.displayName ?? L10n.dahliaAccount
        }
        if let databricksID = model.selectedDatabricksConnectionID {
            return WorkspaceAISettingsModel.shared.databricksConnections.first { $0.id == databricksID }
                .map { L10n.unityGatewayHost($0.hostName) } ?? L10n.databricks
        }
        return L10n.localAccount
    }

    @ViewBuilder
    private var selectedAccountIcon: some View {
        if model.selectedAccountConnectionID != nil {
            Image(systemName: "person.crop.circle")
        } else if model.selectedDatabricksConnectionID != nil {
            Image.databricksLogo.resizable().scaledToFit().frame(width: 16, height: 16)
        } else {
            Image(systemName: "person.2")
        }
    }

}
