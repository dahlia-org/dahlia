import SwiftUI

struct OrganizationAIScopeView: View {
    let organizationID: UUID?
    let projects: [FlatProjectRow]
    let onPrepare: (Int, UUID?, UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var days = 90
    @State private var projectID: UUID?

    var body: some View {
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
        .frame(width: 440, height: 260)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.close) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.prepareChat) {
                    guard let organizationID else { return }
                    onPrepare(days, projectID, organizationID)
                    dismiss()
                }
                .disabled(organizationID == nil)
            }
        }
    }
}
