import SwiftUI

struct ProjectDetailHeaderView: View {
    let projectName: String
    let projectPath: String
    let vaultName: String

    var body: some View {
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
