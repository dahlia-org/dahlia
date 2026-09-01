import SwiftUI

struct SetupTourView: View {
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation
    @ObservedObject private var settings = AppSettings.shared
    @State private var model: SetupTourModel
    @State private var isLanguageMenuHovered = false
    @State private var isCloseHovered = false

    private let vaultManagementModel: VaultManagementModel
    private let canComplete: () -> Bool
    private let onComplete: (VaultRecord) async -> Bool
    private let vaultStepReferenceHeight: CGFloat = 476

    init(
        mode: SetupTourMode,
        currentVault: VaultRecord?,
        vaultManagementModel: VaultManagementModel,
        canComplete: @escaping () -> Bool,
        onComplete: @escaping (VaultRecord) async -> Bool
    ) {
        self.vaultManagementModel = vaultManagementModel
        self.canComplete = canComplete
        self.onComplete = onComplete
        let initialVault = mode == .initial ? currentVault : currentVault ?? vaultManagementModel.vaults.first
        _model = State(initialValue: SetupTourModel(
            mode: mode,
            currentVault: initialVault,
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
                            SetupTourStepHeaderView(step: model.currentStep)

                            stepContent
                                .frame(maxWidth: 900)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 40)
                        .padding(.top, max((proxy.size.height - vaultStepReferenceHeight) / 2, 32))
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
                            Button(action: mainWindowNavigation.dismissSetupTour) {
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
        .windowDismissBehavior(model.mode == .initial || model.isCompleting ? .disabled : .automatic)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.currentStep {
        case .vault:
            VaultSetupStepView(model: model, vaultManagementModel: vaultManagementModel)
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
                onReviewVault: { model.returnToStep(.vault) },
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

    private var canContinue: Bool {
        guard model.canContinue else { return false }
        guard model.currentStep == .workingLanguages,
              settings.appLanguageScope == .selected else { return true }
        return !settings.enabledLanguageIdentifiers.isEmpty
    }

    private func completeTour() {
        guard !requiresVaultSwitch || canComplete() else {
            model.finishCompletion(errorMessage: L10n.vaultOperationFailed)
            return
        }
        model.beginCompletion()
        Task {
            guard !requiresVaultSwitch || canComplete() else {
                model.finishCompletion(errorMessage: L10n.vaultOperationFailed)
                return
            }
            let vault: VaultRecord? = if let originalVault = model.originalVault,
                                         originalVault.url.standardizedFileURL
                                         == model.selectedVaultURL.standardizedFileURL {
                originalVault
            } else {
                await vaultManagementModel.createVault(at: model.selectedVaultURL)
            }
            guard let vault else {
                vaultManagementModel.isShowingError = false
                model.finishCompletion(errorMessage: vaultManagementModel.errorMessage)
                return
            }
            guard await onComplete(vault) else {
                model.finishCompletion(errorMessage: L10n.vaultOperationFailed)
                return
            }
            model.finishCompletion(errorMessage: nil)
        }
    }

    private var requiresVaultSwitch: Bool {
        model.originalVault?.url.standardizedFileURL != model.selectedVaultURL.standardizedFileURL
    }

}
