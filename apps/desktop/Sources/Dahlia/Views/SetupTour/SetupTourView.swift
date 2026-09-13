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
    private let workspaceStepReferenceHeight: CGFloat = 476

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
                        .padding(.top, max((proxy.size.height - workspaceStepReferenceHeight) / 2, 32))
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
        .id(settings.appLanguage)
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
            DahliaServerSignInView(
                cloudConfiguration: accountController.defaultConfiguration,
                allowsCloudSignIn: true,
                isBusy: accountController.isBusy,
                isSigningIn: accountController.isSigningIn,
                errorMessage: accountController.errorMessage,
                onCancel: accountController.cancelAccountTask,
                onSignIn: selectOrSignInToDahlia,
                cloudActionTitle: existingCloudConnection.map {
                    "\($0.displayName) · \(L10n.dahliaCloud)"
                },
                isEmbedded: true,
                onContinueLocally: continueWithLocalAccount
            )
        case .workspace:
            WorkspaceSetupStepView(model: model, workspaceManagementModel: workspaceManagementModel)
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
                onReviewWorkspace: { model.returnToStep(.workspace) },
                onReviewPermissions: { model.returnToStep(.permissions) }
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

    private func continueWithLocalAccount() {
        model.selectAccountConnection(nil)
        model.advance()
    }

    private func selectOrSignInToDahlia(_ configuration: DahliaCloudConfiguration) {
        if let connection = accountController.signedInConnection(matching: configuration) {
            model.selectAccountConnection(connection.id)
            model.advance()
        } else {
            signInToDahlia(configuration)
        }
    }

    private func signInToDahlia(_ configuration: DahliaCloudConfiguration) {
        guard let task = accountController.startSignIn(configuration: configuration) else { return }
        Task { @MainActor in
            await task.value
            guard model.currentStep == .account,
                  accountController.errorMessage == nil,
                  let connection = accountController.completedSignInConnection(matching: configuration) else { return }
            model.selectAccountConnection(connection.id)
            model.advance()
        }
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

    private var existingCloudConnection: DahliaAccountConnection? {
        guard let configuration = accountController.defaultConfiguration else { return nil }
        return accountController.signedInConnection(matching: configuration)
    }

    private func completeTour() {
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
            let workspace: WorkspaceRecord? = if let selectedID = model.selectedExistingWorkspaceID {
                workspaceManagementModel.workspaces.first { $0.id == selectedID && $0.accountConnectionId == model.selectedAccountConnectionID }
            } else if let originalWorkspace = model.originalWorkspace,
                      model.keepsOriginalWorkspace {
                originalWorkspace
            } else if let name = model.selectedWorkspaceName {
                await workspaceManagementModel.createWorkspace(named: name)
            } else {
                await workspaceManagementModel.createWorkspace(at: model.selectedWorkspaceURL)
            }
            guard let workspace else {
                workspaceManagementModel.isShowingError = false
                let errorMessage = workspaceManagementModel.errorMessage
                model.finishCompletion(errorMessage: errorMessage.isEmpty ? L10n.workspaceOperationFailed : errorMessage)
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

}
