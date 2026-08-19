import SwiftUI

struct OrganizationCanvasView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var model: OrganizationWorkspaceViewModel
    @Binding var zoom: CGFloat
    @GestureState private var gestureMagnification: CGFloat = 1
    @State private var scrollPosition = ScrollPosition()

    var body: some View {
        let nodes = model.visibleNodes
        let renderedZoom = OrganizationCanvasZoom.applying(
            magnification: gestureMagnification,
            to: zoom
        )
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
            .scaleEffect(renderedZoom, anchor: .topLeading)
            .frame(
                width: max(model.canvasLayout.size.width * renderedZoom, 320),
                height: max(model.canvasLayout.size.height * renderedZoom, 320),
                alignment: .topLeading
            )
        }
        .scrollPosition($scrollPosition)
        .onChange(of: model.selectedNodeID) { _, id in
            guard let id else { return }
            scrollToNode(id)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .simultaneousGesture(magnifyGesture)
        .accessibilityLabel(L10n.organizationCanvas)
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0)
            .updating($gestureMagnification) { value, magnification, _ in
                magnification = value.magnification
            }
            .onEnded { value in
                zoom = OrganizationCanvasZoom.applying(
                    magnification: value.magnification,
                    to: zoom
                )
            }
    }

    private func scrollToNode(_ id: UUID) {
        if reduceMotion {
            scrollPosition.scrollTo(id: id, anchor: .center)
        } else {
            withAnimation {
                scrollPosition.scrollTo(id: id, anchor: .center)
            }
        }
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
        return ZStack(alignment: .topLeading) {
            nodeSelectionButton(node, isSelected: isSelected)
            nodeCardContent(node)
        }
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
    }

    private func nodeSelectionButton(
        _ node: OrganizationWorkspaceNode,
        isSelected: Bool
    ) -> some View {
        Button {
            Task { await model.selectNode(node.id) }
        } label: {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(node.organization.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func nodeCardContent(_ node: OrganizationWorkspaceNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: node.organization.nodeKind == .organization ? "building.2" : "rectangle.3.group")
                    .dahliaFixedSymbol()
                    .foregroundStyle(.tint)
                Text(node.organization.name)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)

            nodeControls(node)
        }
        .padding(12)
    }

    private func nodeControls(_ node: OrganizationWorkspaceNode) -> some View {
        HStack(spacing: 8) {
            Label("\(node.childCount)", systemImage: "arrow.triangle.branch")
                .allowsHitTesting(false)
            if node.childCount > 0 {
                Button {
                    Task { await model.toggleExpansion(node.id) }
                } label: {
                    Image(systemName: model.expandedNodeIDs.contains(node.id)
                        ? "chevron.down.circle" : "chevron.right.circle")
                        .dahliaFixedSymbol()
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
                .font(.callout)
                .disabled(model.loadingChildNodeIDs.contains(node.id))
            }
        }
        .font(.callout)
        .foregroundStyle(DahliaDesign.secondaryTextColor)
    }
}
