import GRDB
import SwiftUI

struct DataProtectionSettingsView: View {
    private enum Tab: CaseIterable, Identifiable {
        case protection
        case backups

        var id: Self { self }

        var label: String {
            switch self {
            case .protection: L10n.dataProtection
            case .backups: L10n.backups
            }
        }
    }

    let dbQueue: DatabaseQueue?
    @ObservedObject var captionViewModel: CaptionViewModel
    let onShowUnprocessedRecordings: (UUID) -> Void
    @State private var selection = Tab.protection

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    EmptyView()
                } header: {
                    UnderlineTabBar(tabs: Tab.allCases, selection: $selection, label: \.label, accessibilityLabel: L10n.dataProtection)
                }
            }
            .formStyle(.grouped)
            .font(.dahliaBody)
            .fixedSize(horizontal: false, vertical: true)

            switch selection {
            case .protection:
                DataProtectionPreferencesView()
            case .backups:
                BackupSettingsView(
                    dbQueue: dbQueue,
                    captionViewModel: captionViewModel,
                    onShowUnprocessedRecordings: onShowUnprocessedRecordings
                )
            }
        }
    }
}
