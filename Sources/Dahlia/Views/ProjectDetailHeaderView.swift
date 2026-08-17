import SwiftUI

struct ProjectDetailHeaderView: View {
    let projectName: String
    let projectPath: String
    let vaultName: String
    let appearance: ProjectAppearance
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProjectAppearanceIcon(appearance: appearance)
                .font(.title2)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(projectName)
                    .font(.title2)
                    .bold()

                Label {
                    Text("\(vaultName) › \(displayPath)")
                } icon: {
                    Image(systemName: "externaldrive")
                }
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            Button(L10n.editProject, systemImage: "pencil", action: onEdit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top)
    }

    private var displayPath: String {
        projectPath
            .split(separator: "/")
            .map(String.init)
            .joined(separator: " › ")
    }
}
