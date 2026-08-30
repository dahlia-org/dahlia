import SwiftUI

struct SetupTourActionBarView: View {
    let step: SetupTourStep
    let canGoBack: Bool
    let canContinue: Bool
    let isCompleting: Bool
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            HStack {
                Button(action: onBack) {
                    Text(L10n.back)
                        .frame(minWidth: 96, minHeight: 28)
                }
                .buttonStyle(.dahlia())
                .controlSize(.large)
                .disabled(!canGoBack)

                Spacer(minLength: 24)

                Button(action: onContinue) {
                    Group {
                        if isCompleting {
                            ProgressView()
                                .accessibilityLabel(primaryLabel)
                        } else {
                            Text(primaryLabel)
                        }
                    }
                    .frame(minWidth: 116, minHeight: 28)
                }
                .buttonStyle(.dahlia(.primary))
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }

            SetupTourProgressOverlayView(currentStep: step)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var primaryLabel: String {
        step == .completion ? L10n.startDahlia : L10n.continueAction
    }
}
