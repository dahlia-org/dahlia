import SwiftUI

struct DatabricksCLIInstallGuideView: View {
    let onInstall: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            DahliaSheetHeader(title: L10n.installDatabricksCLI)

            Form {
                Section {
                    Text(L10n.databricksCLIInstallOverview)
                }

                Section {
                    Text(DatabricksCLIInstaller.command)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Text(L10n.databricksCLIInstallCommand)
                } footer: {
                    Text(L10n.databricksCLIInstallCommandDescription)
                }

                Section {
                    Link(L10n.viewOfficialInstallGuide, destination: Self.installGuideURL)
                    Link(L10n.viewDatabricksLicense, destination: Self.licenseURL)
                    Link(L10n.viewDatabricksPrivacyNotice, destination: Self.privacyNoticeURL)
                }
            }
            .formStyle(.grouped)

            DahliaSheetActionBar {
                Button(L10n.cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.installInTerminal, systemImage: "terminal") {
                    onInstall()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .dahliaSimpleWindowStyle()
    }

    private static let installGuideURL = URL(string: "https://docs.databricks.com/aws/en/dev-tools/cli/install")!
    private static let licenseURL = URL(string: "https://github.com/databricks/cli/blob/main/LICENSE")!
    private static let privacyNoticeURL = URL(string: "https://www.databricks.com/legal/privacynotice")!
}
