import SwiftUI

struct ProjectManagementTreeRow: View {
    let node: ProjectTreeNode
    let selectedProjectId: UUID?
    let requestedExpandedProjectIds: Set<UUID>

    @State private var isExpanded = false

    var body: some View {
        Group {
            if let children = node.children {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(children) { child in
                        Self(
                            node: child,
                            selectedProjectId: selectedProjectId,
                            requestedExpandedProjectIds: requestedExpandedProjectIds
                        )
                    }
                } label: {
                    ProjectManagementRowContent(
                        node: node,
                        isSelected: selectedProjectId == node.id
                    )
                }
                .tag(node.id)
            } else {
                ProjectManagementRowContent(
                    node: node,
                    isSelected: selectedProjectId == node.id
                )
                .tag(node.id)
            }
        }
        .onAppear(perform: applyExpansionRequest)
        .onChange(of: requestedExpandedProjectIds, applyExpansionRequest)
    }

    private func applyExpansionRequest() {
        if requestedExpandedProjectIds.contains(node.id) {
            isExpanded = true
        }
    }
}
