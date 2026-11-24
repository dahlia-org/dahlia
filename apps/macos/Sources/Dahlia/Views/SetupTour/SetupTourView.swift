import SwiftUI

struct SetupTourView: View {
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation
    @ObservedObject private var settings = AppSettings.shared
    @State private var model: SetupTourModel
    @State private var isLanguageMenuHovered = false
    @State private var isCloseHovered = false
    @State private var isInstallingPi = false

    private let workspaceManagementModel: WorkspaceManagementModel
    private let canComplete: () -> Bool
    private let onComplete: (WorkspaceRecord) async -> Bool
    private let stepReferenceHeight: CGFloat = 476

    init(
        mode: SetupTourMode,
        currentWorkspace: WorkspaceRecord?,
        workspaceManagementModel: WorkspaceManagementModel,
        canComplete: @escaping () -> Bool,
        onComplete: @escaping (WorkspaceRecord) async -> Bool
    ) {
        self.workspaceManagementModel = workspaceManagementModel
        self.canComplete = canComplete
        self.onComplete = onComplete
        let initialWorkspace = mode == .initial ? currentWorkspace : currentWorkspace ?? workspaceManagementModel.workspaces.first
        _model = State(initialValue: SetupTourModel(
            mode: mode,
            currentWorkspace: initialWorkspace,
            progressDefaults: .standard
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            DahliaWindowHeader(reservesWindowControls: true) {
                Text(L10n.setupDahlia)
                    .font(.dahliaHeadline)

                Spacer()
            }

            GeometryReader { proxy in
                ZStack(alignment: .topTrailing) {
                    ScrollView {
                        VStack(spacing: 28) {
                            if model.isCheckingPi {
                                ProgressView()
                            } else {
                                SetupTourStepHeaderView(step: model.currentStep)

                                stepContent
                                    .frame(maxWidth: 900)
                            }
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
                                    .font(.dahliaSecondary)
                            }
                            .font(.dahliaBody)
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
                        .disabled(isInstallingPi)
                        .fixedSize()
                        .onHover { isLanguageMenuHovered = $0 }
                        .accessibilityLabel(L10n.appLanguage)
                        .accessibilityValue(settings.appLanguage.displayName)

                        if model.mode == .manual {
                            Button(action: dismissTour) {
                                Label(L10n.close, systemImage: "xmark")
                                    .labelStyle(.iconOnly)
                                    .font(.dahliaBody)
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
                            .disabled(!model.canDismiss || isInstallingPi)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 16)
                }
            }

            SetupTourActionBarView(
                step: model.currentStep,
                steps: model.visibleSteps,
                canGoBack: model.canGoBack && !isInstallingPi,
                canContinue: canContinue,
                isCompleting: model.isCompleting,
                onBack: model.goBack,
                onContinue: continueTour
            )
        }
        .task {
            await model.checkPi()
            guard !Task.isCancelled, model.mode == .initial else { return }
            _ = await prepareInitialWorkspace()
        }
        .id(settings.appLanguage)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .windowDismissBehavior(
            !model.canDismiss || isInstallingPi ? .disabled : .automatic
        )
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.currentStep {
        case .workingLanguages:
            WorkingLanguagesSetupStepView()
        case .pi:
            PiSetupStepView(isInstalling: $isInstallingPi)
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

    private var canContinue: Bool {
        guard model.canContinue, !isInstallingPi else { return false }
        guard model.currentStep == .workingLanguages,
              settings.appLanguageScope == .selected else { return true }
        return !settings.enabledLanguageIdentifiers.isEmpty
    }

    private func dismissTour() {
        guard model.canDismiss, !isInstallingPi else { return }
        mainWindowNavigation.dismissSetupTour()
    }

    private func prepareInitialWorkspace() async -> WorkspaceRecord? {
        await model.prepareInitialWorkspace {
            let workspace = await workspaceManagementModel.resolveInitialWorkspace()
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
                // A manual tour without an open workspace opens the account's workspace.
                await WorkspaceAISettingsModel.shared.accountWorkspace()
            }
            guard let workspace else {
                workspaceManagementModel.isShowingError = false
                model.finishCompletion(
                    errorMessage: model.mode == .initial ? L10n.setupWorkspaceUnavailable : L10n.workspaceOperationFailed
                )
                return
            }
            guard await onComplete(workspace) else {
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
