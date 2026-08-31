import AppKit
import SwiftUI

struct DahliaServerSignInView: View {
    let cloudConfiguration: DahliaCloudConfiguration?
    let isBusy: Bool
    let isSigningIn: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onSignIn: (DahliaCloudConfiguration) -> Void

    @State private var serverURL = ""
    @State private var isCloseHovered = false

    var body: some View {
        ZStack {
            Button(action: onCancel) {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)

            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    Text(L10n.dahlia)
                        .font(.largeTitle)
                        .bold()
                        .accessibilityAddTraits(.isHeader)
                }

                Text(L10n.dahliaSignInDescription)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if isSigningIn {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.dahliaWaitingForBrowser)
                        .foregroundStyle(.secondary)

                    Button(L10n.cancelSignIn, action: onCancel)
                        .buttonStyle(.dahlia())
                } else {
                    if let errorMessage {
                        SettingsStatusMessage(
                            text: errorMessage,
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .red
                        )
                    } else if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button(action: signInToCloud) {
                        Text(Self.cloudActionTitle(isConfigured: cloudConfiguration != nil))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.dahlia(.primary))
                    .disabled(isBusy || cloudConfiguration == nil)

                    ZStack {
                        Divider()
                        Text(L10n.orConnectToServer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .background(.background)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.serverURL)
                            .font(.body)
                        TextField("https://dahlia.example.com", text: $serverURL)
                            .textContentType(.URL)
                            .onSubmit(connect)
                            .disabled(isBusy)

                        Button(action: connect) {
                            Text(L10n.connect)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.dahlia())
                        .disabled(isBusy || serverConfiguration == nil)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 440, maxHeight: .infinity)
            .frame(width: 500, height: 400)
            .overlay(alignment: .topTrailing) {

                Button(L10n.close, systemImage: "xmark", action: onCancel)
                    .labelStyle(.iconOnly)
                    .dahliaFixedSymbol()
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
                    .background(
                        isCloseHovered ? DahliaDesign.contentHighlightColor : .clear,
                        in: .rect(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
                    )
                    .onHover { isCloseHovered = $0 }
                    .keyboardShortcut(.cancelAction)
                    .help(L10n.close)
                    .padding(12)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(.rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
            .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
        }
        .transition(.identity)
    }

    private var serverConfiguration: DahliaCloudConfiguration? {
        Self.serverConfiguration(urlString: serverURL)
    }

    private func connect() {
        guard let serverConfiguration else { return }
        onSignIn(serverConfiguration)
    }

    private func signInToCloud() {
        guard let cloudConfiguration else { return }
        onSignIn(cloudConfiguration)
    }

    static func cloudActionTitle(isConfigured: Bool) -> String {
        isConfigured ? L10n.signInToDahliaCloud : L10n.dahliaCloudComingSoon
    }

    static func serverConfiguration(urlString: String) -> DahliaCloudConfiguration? {
        DahliaCloudConfiguration.make(urlString: urlString, clientID: DahliaCloudConfiguration.defaultClientID)
    }
}
