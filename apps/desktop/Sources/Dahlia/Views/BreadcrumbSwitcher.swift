import SwiftUI

struct BreadcrumbSwitcher<Options: View>: View {
    let title: String
    let systemImage: String
    var arrowEdge: Edge = .bottom
    let action: () -> Void
    @ViewBuilder let options: Options

    @Environment(\.breadcrumbAncestorIDs) private var ancestorIDs
    @Environment(BreadcrumbHoverSession.self) private var hoverSession
    @State private var hoverID = UUID()
    @State private var isTriggerHovered = false
    @State private var isContentHovered = false
    @State private var isPresented = false

    var body: some View {
        Button {
            hoverSession.dismissAll()
            isPresented = false
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: arrowEdge == .bottom ? nil : .infinity, alignment: .leading)
                if arrowEdge == .trailing {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
            }
            .font(arrowEdge == .trailing ? .body.bold() : .body)
            .foregroundStyle(arrowEdge == .bottom ? Color.secondary : DahliaDesign.sidebarPrimaryTextColor)
            .padding(6)
            .contentShape(.rect)
            .background(
                isTriggerHovered ? DahliaDesign.contentHighlightColor : .clear,
                in: .rect(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
            )
        }
        .buttonStyle(.plain)
        .allowsWindowActivationEvents(true)
        .help(title)
        .onKeyPress(.downArrow) {
            isPresented = true
            return .handled
        }
        .onChange(of: hoverSession.dismissalGeneration) {
            isTriggerHovered = false
            isContentHovered = false
            isPresented = false
            updateHover()
        }
        .onHover {
            isTriggerHovered = $0
            updateHover()
        }
        .accessibilityAction(named: Text(L10n.actions)) { isPresented = true }
        .background {
            BreadcrumbPopover(isPresented: $isPresented, arrowEdge: arrowEdge) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        options
                    }
                    .padding(6)
                }
                .frame(width: 280)
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                .environment(hoverSession)
                .environment(\.breadcrumbAncestorIDs, ancestorIDs + [hoverID])
                .onKeyPress(.escape) {
                    hoverSession.dismissAll()
                    return .handled
                }
                .onHover {
                    isContentHovered = $0
                    updateHover()
                }
                .onDisappear {
                    isContentHovered = false
                    updateHover()
                }
            }
        }
        .task(id: hoverSession.isHovered(id: hoverID)) {
            let isHovered = hoverSession.isHovered(id: hoverID)
            if isHovered, isPresented { return }
            do {
                try await Task.sleep(for: .milliseconds(isHovered ? 300 : 150))
                isPresented = isHovered
            } catch {}
        }
        .onDisappear {
            hoverSession.update(id: hoverID, ancestors: ancestorIDs, isHovered: false)
        }
    }

    private func updateHover() {
        hoverSession.update(id: hoverID, ancestors: ancestorIDs, isHovered: isTriggerHovered || isContentHovered)
    }
}
