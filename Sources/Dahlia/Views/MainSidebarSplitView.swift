import AppKit
import SwiftUI

struct MainSidebarSplitView<Sidebar: View, Detail: View>: View {
    private static var animationDuration: TimeInterval { 0.3 }

    let width: CGFloat
    let isVisible: Bool
    let onWidthChange: (CGFloat) -> Void
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let detail: Detail

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var resizeTranslation: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let restingSidebarWidth = MainSidebarLayout.effectiveWidth(
                width,
                availableWidth: geometry.size.width
            )
            let sidebarWidth = MainSidebarLayout.effectiveWidth(
                restingSidebarWidth + resizeTranslation,
                availableWidth: geometry.size.width
            )
            let visibleSidebarWidth = isVisible ? sidebarWidth : 0

            ZStack(alignment: .leading) {
                sidebar
                    .frame(width: sidebarWidth, height: geometry.size.height)
                    .opacity(isVisible ? 1 : 0)
                    .animation(
                        reduceMotion || isVisible ? nil : .easeOut(duration: Self.animationDuration),
                        value: isVisible
                    )
                    .mainSidebarBackground()
                    .allowsHitTesting(isVisible)
                    .disabled(!isVisible)
                    .accessibilityHidden(!isVisible)

                detail
                    .frame(
                        width: max(geometry.size.width - visibleSidebarWidth, 0),
                        height: geometry.size.height
                    )
                    .offset(x: visibleSidebarWidth)
                    .animation(reduceMotion ? nil : .smooth(duration: Self.animationDuration), value: isVisible)
                    .zIndex(1)

                if isVisible {
                    Color.clear
                        .frame(width: 8, height: geometry.size.height)
                        .overlay {
                            Rectangle()
                                .fill(Color(nsColor: .separatorColor))
                                .frame(width: 0.5)
                        }
                        .contentShape(.rect)
                        .offset(x: sidebarWidth - 4)
                        .gesture(resizeGesture(from: restingSidebarWidth, availableWidth: geometry.size.width))
                        .accessibilityElement()
                        .accessibilityLabel(L10n.resize)
                        .accessibilityValue(Int(sidebarWidth).formatted())
                        .accessibilityAdjustableAction { direction in
                            resizeSidebar(
                                direction,
                                from: restingSidebarWidth,
                                availableWidth: geometry.size.width
                            )
                        }
                        .onContinuousHover { phase in
                            (phase == .ended ? NSCursor.arrow : NSCursor.resizeLeftRight).set()
                        }
                        .zIndex(2)
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .leading
            )
            .background {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
            }
        }
        .frame(minWidth: isVisible ? MainSidebarLayout.minimumSplitWidth : MainSidebarLayout.minimumDetailWidth)
    }

    private func resizeGesture(from width: CGFloat, availableWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($resizeTranslation) { value, translation, _ in
                translation = value.translation.width
            }
            .onEnded { value in
                onWidthChange(MainSidebarLayout.effectiveWidth(
                    width + value.translation.width,
                    availableWidth: availableWidth
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
        onWidthChange(MainSidebarLayout.effectiveWidth(
            width + adjustment,
            availableWidth: availableWidth
        ))
    }
}
