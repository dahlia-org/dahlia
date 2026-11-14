import SwiftUI

struct CodexChatScopeBar: View {
    let session: CodexChatSessionModel
    let sidebarViewModel: SidebarViewModel
    @State private var isHovering = false

    private var projectName: String {
        guard session.scopeSnapshot != nil else { return L10n.loadingProjects }
        return session.scopeSnapshot?.projects.first { $0.id == session.scopeProjectID }?.path ?? L10n.noProject
    }

    var body: some View {
        HStack(spacing: 8) {
            if session.canSelectScope {
                Menu {
                    Button(L10n.noProject) { session.selectScopeProject(nil) }
                    Divider()
                    ForEach(session.scopeSnapshot?.projects ?? []) { project in
                        Button(project.path) { session.selectScopeProject(project.id) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Label(projectName, systemImage: "folder")
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .imageScale(.small)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: CodexChatDesign.controlSize)
                    .background(isHovering ? DahliaDesign.contentHighlightColor : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .onHover { isHovering = $0 }
                .disabled(session.scopeSnapshot == nil)
                .help(L10n.chatSelectProject)
            } else {
                Label(projectName, systemImage: "folder")
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: CodexChatDesign.controlSize)
                    .help(projectName)
            }
            Spacer(minLength: 0)
        }
        .font(.dahliaSecondary)
        .foregroundStyle(DahliaDesign.secondaryTextColor)
        .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .task(
            id: "\(session.id.rawValue)-\(session.backendThreadID ?? "new")-\(session.scopeContextRevision)-\(session.hasSelectedProject)-\(sidebarViewModel.dbQueue != nil)"
        ) {
            await session.observeScope(dbQueue: sidebarViewModel.dbQueue)
        }
    }
}
