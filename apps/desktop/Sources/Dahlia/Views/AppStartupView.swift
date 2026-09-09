import AppKit
import SwiftUI

struct AppStartupView: View {
    let state: AppStartupModel.State
    let onContinue: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DahliaWindowHeader(reservesWindowControls: true) {
                Spacer()
            }
            VStack(spacing: 20) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .accessibilityHidden(true)

                Text(L10n.dahlia)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)

                switch state {
                case let .working(phase):
                    ProgressView()
                        .controlSize(.large)
                        .accessibilityLabel(title(for: phase))
                    Text(title(for: phase))
                        .font(.title2)
                    Text(phase == .restoring || phase == .updating ? L10n.startupDataWait : L10n.startupWait)
                        .foregroundStyle(.secondary)
                case let .failed(details, canContinue):
                    Label(canContinue ? L10n.startupRestoreFailed : L10n.startupFailed, systemImage: "exclamationmark.triangle")
                        .font(.title2)
                        .accessibilityAddTraits(.isHeader)
                    Text(canContinue ? L10n.startupRestoreFailureHelp : L10n.startupFailureHelp)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(details)
                            .font(.callout)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    HStack {
                        Button(L10n.startupQuit, action: onQuit)
                            .buttonStyle(.dahlia())
                        if canContinue {
                            Button(L10n.continueAction, action: onContinue)
                                .buttonStyle(.dahlia(.primary))
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                case .ready:
                    EmptyView()
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func title(for phase: AppStartupModel.Phase) -> String {
        switch phase {
        case .preparing: L10n.startupPreparing
        case .restoring: L10n.startupRestoring
        case .updating: L10n.startupUpdating
        case .loadingVaults: L10n.loadingVaults
        }
    }
}

#Preview("Preparing") {
    AppStartupView(state: .working(.preparing), onContinue: {}, onQuit: {})
        .frame(width: 720, height: 520)
}

#Preview("Restoring") {
    AppStartupView(state: .working(.restoring), onContinue: {}, onQuit: {})
        .frame(width: 720, height: 520)
}

#Preview("Updating") {
    AppStartupView(state: .working(.updating), onContinue: {}, onQuit: {})
        .frame(width: 720, height: 520)
}

#Preview("Loading Vaults") {
    AppStartupView(state: .working(.loadingVaults), onContinue: {}, onQuit: {})
        .frame(width: 720, height: 520)
}

#Preview("Failed") {
    AppStartupView(state: .failed(details: "Database could not be opened.", canContinue: false), onContinue: {}, onQuit: {})
        .frame(width: 720, height: 520)
}

#Preview("Restore Warning") {
    AppStartupView(state: .failed(details: "Backup could not be restored.", canContinue: true), onContinue: {}, onQuit: {})
        .frame(width: 720, height: 520)
}
