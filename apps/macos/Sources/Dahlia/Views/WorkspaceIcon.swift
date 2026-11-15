import SwiftUI

struct WorkspaceIcon: View {
    let workspace: WorkspaceRecord

    var body: some View {
        ProjectAppearanceIcon(appearance: workspace.appearance ?? .workspaceDefault)
            .workspaceExportFolderBadge(isVisible: workspace.path != nil)
            .accessibilityHidden(true)
    }
}

extension View {
    func workspaceExportFolderBadge(isVisible: Bool) -> some View {
        overlay(alignment: .bottomTrailing) {
            if isVisible {
                Image(systemName: "folder.fill")
                    .font(.system(size: DahliaTypography.size(offset: -6)))
                    .foregroundStyle(.secondary)
                    .padding(1)
                    .background(.background, in: .rect(cornerRadius: 2))
                    .offset(x: 4, y: 3)
                    .accessibilityHidden(true)
            }
        }
    }
}
