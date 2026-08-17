import SwiftUI

struct ProjectManagementTreeRow: View {
    let node: ProjectTreeNode
    let selectedProjectId: UUID?
    @Binding var expandedProjectIds: Set<UUID>
    let expandsAllDescendants: Bool
    let appearanceForProject: (UUID) -> ProjectAppearance

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: expansionBinding) {
                ForEach(children) { child in
                    Self(
                        node: child,
                        selectedProjectId: selectedProjectId,
                        expandedProjectIds: $expandedProjectIds,
                        expandsAllDescendants: expandsAllDescendants,
                        appearanceForProject: appearanceForProject
                    )
                }
            } label: {
                ProjectManagementRowContent(
                    node: node,
                    isSelected: selectedProjectId == node.id,
                    appearance: appearanceForProject(node.id)
                )
            }
            .tag(node.id)
        } else {
            ProjectManagementRowContent(
                node: node,
                isSelected: selectedProjectId == node.id,
                appearance: appearanceForProject(node.id)
            )
            .tag(node.id)
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expandsAllDescendants || expandedProjectIds.contains(node.id) },
            set: { expanded in
                if !expandsAllDescendants {
                    if expanded {
                        expandedProjectIds.insert(node.id)
                    } else {
                        expandedProjectIds.remove(node.id)
                    }
                }
            }
        )
    }
}
