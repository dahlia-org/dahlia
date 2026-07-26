import SwiftUI

struct OrganizationCanvasView: View {
    var model: OrganizationWorkspaceViewModel
    @Binding var zoom: CGFloat

    var body: some View {
        let nodes = model.visibleNodes
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    relationshipLines(nodes)
                    ForEach(nodes) { node in
                        if let position = model.canvasLayout.positions[node.id] {
                            nodeCard(node)
                                .frame(
                                    width: OrganizationCanvasLayout.nodeSize.width,
                                    height: OrganizationCanvasLayout.nodeSize.height
                                )
                                .position(
                                    x: position.x + OrganizationCanvasLayout.nodeSize.width / 2,
                                    y: position.y + OrganizationCanvasLayout.nodeSize.height / 2
                                )
                                .id(node.id)
                        }
                    }
                }
                .frame(
                    width: max(model.canvasLayout.size.width, 320),
                    height: max(model.canvasLayout.size.height, 320),
                    alignment: .topLeading
                )
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(
                    width: max(model.canvasLayout.size.width * zoom, 320),
                    height: max(model.canvasLayout.size.height * zoom, 320),
                    alignment: .topLeading
                )
            }
            .onChange(of: model.selectedNodeID) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: model.canvasLayout) { _, _ in
                guard let id = model.selectedNodeID else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityLabel(L10n.organizationCanvas)
    }

    private func relationshipLines(_ nodes: [OrganizationWorkspaceNode]) -> some View {
        Canvas { context, _ in
            for node in nodes {
                guard let parentID = node.organization.parentOrganizationId,
                      let parent = model.canvasLayout.positions[parentID],
                      let child = model.canvasLayout.positions[node.id] else { continue }
                var path = Path()
                path.move(to: CGPoint(
                    x: parent.x + OrganizationCanvasLayout.nodeSize.width,
                    y: parent.y + OrganizationCanvasLayout.nodeSize.height / 2
                ))
                let childPoint = CGPoint(
                    x: child.x,
                    y: child.y + OrganizationCanvasLayout.nodeSize.height / 2
                )
                let middleX = (parent.x + OrganizationCanvasLayout.nodeSize.width + child.x) / 2
                path.addCurve(
                    to: childPoint,
                    control1: CGPoint(
                        x: middleX,
                        y: parent.y + OrganizationCanvasLayout.nodeSize.height / 2
                    ),
                    control2: CGPoint(x: middleX, y: childPoint.y)
                )
                context.stroke(path, with: .color(.secondary.opacity(0.45)), lineWidth: 1.5)
            }
        }
    }

    private func nodeCard(_ node: OrganizationWorkspaceNode) -> some View {
        let isSelected = model.selectedNodeID == node.id
        let isTopicRelated = model.selectedTopicID == nil
            || model.highlightedOrganizationIDs.isEmpty
            || model.highlightedOrganizationIDs.contains(node.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await model.selectNode(node.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: node.organization.nodeKind == .organization ? "building.2" : "rectangle.3.group")
                        .foregroundStyle(.tint)
                    Text(node.organization.name)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Label("\(node.childCount)", systemImage: "arrow.triangle.branch")
                if node.childCount > 0 {
                    Button {
                        Task { await model.toggleExpansion(node.id) }
                    } label: {
                        Image(systemName: model.expandedNodeIDs.contains(node.id)
                            ? "chevron.down.circle" : "chevron.right.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        model.expandedNodeIDs.contains(node.id) ? L10n.collapse : L10n.expand
                    )
                }
                if model.expandedNodeIDs.contains(node.id),
                   (model.loadedChildCounts[node.id] ?? 0) < node.childCount {
                    Button(L10n.loadMore) {
                        Task { await model.loadMoreChildren(of: node.id) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(model.loadingChildNodeIDs.contains(node.id))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
                .stroke(
                    isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(.rect)
        .opacity(isTopicRelated ? 1 : 0.28)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
