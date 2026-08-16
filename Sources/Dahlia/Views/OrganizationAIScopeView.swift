import SwiftUI

struct OrganizationAIScopeView: View {
    let organizationID: UUID?
    let projects: [FlatProjectRow]
    let onPrepare: (Int, UUID?, UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var days = 90
    @State private var projectID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            DahliaSheetHeader(title: L10n.analysisScope)

            Form {
                Section(L10n.analysisScope) {
                    Stepper(L10n.pastDays(days), value: $days, in: 1 ... 365)
                    Picker(L10n.project, selection: $projectID) {
                        Text(L10n.allProjects).tag(UUID?.none)
                        ForEach(projects, id: \.id) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                }
                Text(L10n.aiScopeDoesNotSend)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            DahliaSheetActionBar {
                Button(L10n.close) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.prepareChat) {
                    guard let organizationID else { return }
                    onPrepare(days, projectID, organizationID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(organizationID == nil)
            }
        }
        .frame(width: 440, height: 260)
        .dahliaSimpleWindowStyle()
    }
}
