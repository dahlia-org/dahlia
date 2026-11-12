import SwiftUI

struct PiSetupStepView: View {
    @Binding var isInstalling: Bool
    @State private var model: PiSetupModel

    init(account: CodexRuntimeProvider, isInstalling: Binding<Bool>) {
        _isInstalling = isInstalling
        _model = State(initialValue: PiSetupModel(account: account))
    }

    var body: some View {
        Form {
            Section {
                if model.isReady {
                    Label(L10n.useManagedPi, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else if isInstalling {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(L10n.installPi)
                        Spacer()
                        Button(L10n.cancel) { isInstalling = false }
                            .buttonStyle(.dahlia())
                    }
                } else {
                    Button(model.hasManagedPi ? L10n.useManagedPi : L10n.installPi) {
                        isInstalling = true
                    }
                    .buttonStyle(.dahlia(.primary))
                    .disabled(model.isCheckingInstallation)
                }
                if let errorMessage = model.errorMessage {
                    SettingsStatusMessage(text: errorMessage, systemImage: "exclamationmark.triangle.fill", tint: .red)
                }
            } footer: {
                Text(L10n.piSetupSkipDescription)
            }
        }
        .formStyle(.grouped)
        .font(.dahliaBody)
        .frame(height: 300)
        .task { await model.refresh() }
        .task(id: isInstalling) {
            guard isInstalling else { return }
            await model.install()
            guard !Task.isCancelled else { return }
            isInstalling = false
        }
    }
}
