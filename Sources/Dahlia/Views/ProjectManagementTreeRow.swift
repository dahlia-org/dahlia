import SwiftUI

struct ProjectManagementTreeRow: View {
    let node: ProjectTreeNode
    let selectedProjectId: UUID?
    let requestedExpandedProjectIds: Set<UUID>
    let expandsAllDescendants: Bool

    @State private var isExpanded = false

    var body: some View {
        Group {
            if let children = node.children {
                DisclosureGroup(isExpanded: expansionBinding) {
                    ForEach(children) { child in
                        Self(
                            node: child,
                            selectedProjectId: selectedProjectId,
                            requestedExpandedProjectIds: requestedExpandedProjectIds,
                            expandsAllDescendants: expandsAllDescendants
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

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expandsAllDescendants || isExpanded },
            set: { expanded in
                if !expandsAllDescendants {
                    isExpanded = expanded
                }
            }
        )
    }

    private func applyExpansionRequest() {
        if requestedExpandedProjectIds.contains(node.id) {
            isExpanded = true
        }
    }
}
