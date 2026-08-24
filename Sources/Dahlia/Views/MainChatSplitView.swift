import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var isChatSidebarResizing = false
}

struct MainChatSplitView<Content: View, Sidebar: View>: View {
    private static var animationDuration: TimeInterval { 0.3 }

    let width: CGFloat
    let contentMinimumWidth: CGFloat
    let isVisible: Bool
    let onWidthChange: (CGFloat) -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let sidebar: Sidebar

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var resizeTranslation: CGFloat = 0
    @GestureState private var isResizing = false

    var body: some View {
        GeometryReader { geometry in
            let restingSidebarWidth = MainChatSidebarLayout.effectiveWidth(
                width,
                availableWidth: geometry.size.width,
                contentMinimumWidth: contentMinimumWidth
            )
            let sidebarWidth = MainChatSidebarLayout.effectiveWidth(
                restingSidebarWidth - resizeTranslation,
                availableWidth: geometry.size.width,
                contentMinimumWidth: contentMinimumWidth
            )
            let visibleSidebarWidth = isVisible ? sidebarWidth : 0

            ZStack(alignment: .trailing) {
                content
                    .frame(
                        width: max(geometry.size.width - visibleSidebarWidth, 0),
                        height: geometry.size.height
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isVisible {
                    sidebar
                        .environment(\.isChatSidebarResizing, isResizing)
                        .frame(width: sidebarWidth, height: geometry.size.height)
                        .background(alignment: .leading) {
                            Color(nsColor: .windowBackgroundColor)
                                .ignoresSafeArea()
                            Rectangle()
                                .fill(Color(nsColor: .separatorColor))
                                .frame(width: 1)
                        }
                        .transition(.move(edge: .trailing))

                    resizeHandle(
                        currentWidth: sidebarWidth,
                        restingWidth: restingSidebarWidth,
                        availableWidth: geometry.size.width
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .animation(reduceMotion ? nil : .smooth(duration: Self.animationDuration), value: isVisible)
        }
        .frame(minWidth: isVisible ? MainChatSidebarLayout.minimumWidth + contentMinimumWidth : contentMinimumWidth)
    }

    private func resizeHandle(currentWidth: CGFloat, restingWidth: CGFloat, availableWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: 8)
            .contentShape(.rect)
            .offset(x: -currentWidth + 4)
            .gesture(resizeGesture(from: restingWidth, availableWidth: availableWidth))
            .accessibilityElement()
            .accessibilityLabel(L10n.resize)
            .accessibilityValue(Int(currentWidth).formatted())
            .accessibilityAdjustableAction { direction in
                resizeSidebar(direction, from: restingWidth, availableWidth: availableWidth)
            }
            .onContinuousHover { phase in
                (phase == .ended ? NSCursor.arrow : NSCursor.resizeLeftRight).set()
            }
    }

    private func resizeGesture(from width: CGFloat, availableWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($resizeTranslation) { value, translation, transaction in
                transaction.disablesAnimations = true
                translation = value.translation.width
            }
            .updating($isResizing) { _, isResizing, _ in
                isResizing = true
            }
            .onEnded { value in
                onWidthChange(MainChatSidebarLayout.effectiveWidth(
                    width - value.translation.width,
                    availableWidth: availableWidth,
                    contentMinimumWidth: contentMinimumWidth
                ))
            }
    }

    private func resizeSidebar(
        _ direction: AccessibilityAdjustmentDirection,
        from width: CGFloat,
        availableWidth: CGFloat
    ) {
        let adjustment: CGFloat = switch direction {
        case .increment: 10
        case .decrement: -10
        @unknown default: 0
        }
        onWidthChange(MainChatSidebarLayout.effectiveWidth(
            width + adjustment,
            availableWidth: availableWidth,
            contentMinimumWidth: contentMinimumWidth
        ))
    }
}
