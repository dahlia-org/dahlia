import SwiftUI

struct MeetingTitleMarquee: View {
    private static var pointsPerSecond: CGFloat { 32 }

    let isHovered: Bool
    let title: Text

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var titleWidth: CGFloat = 0
    @State private var separatorWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var scrollStartedAt: Date?

    var body: some View {
        TimelineView(.animation(paused: !isScrolling)) { timeline in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    title
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .onGeometryChange(for: CGFloat.self) { geometry in
                            geometry.size.width
                        } action: { width in
                            titleWidth = width
                            updateScrollStart()
                        }

                    Text(verbatim: " ")
                        .fixedSize(horizontal: true, vertical: false)
                        .onGeometryChange(for: CGFloat.self) { geometry in
                            geometry.size.width
                        } action: { separatorWidth = $0 }

                    title
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .opacity(isScrolling ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .offset(x: horizontalOffset(at: timeline.date))
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(true)
            .allowsHitTesting(false)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { width in
                viewportWidth = width
                updateScrollStart()
            }
        }
        .onChange(of: isHovered) { _, _ in
            updateScrollStart()
        }
        .onChange(of: reduceMotion) { _, _ in
            updateScrollStart()
        }
        .onDisappear { scrollStartedAt = nil }
    }

    private var titleOverflowsViewport: Bool {
        titleWidth - viewportWidth > 1
    }

    private var isScrolling: Bool {
        isHovered && titleOverflowsViewport && !reduceMotion
    }

    private func updateScrollStart() {
        scrollStartedAt = isScrolling ? Date() : nil
    }

    private func horizontalOffset(at date: Date) -> CGFloat {
        guard isScrolling, let scrollStartedAt else { return 0 }
        let travelDistance = titleWidth + separatorWidth
        guard travelDistance > 0 else { return 0 }
        let elapsed = max(0, date.timeIntervalSince(scrollStartedAt))
        let distance = CGFloat(elapsed) * Self.pointsPerSecond
        return -distance.truncatingRemainder(dividingBy: travelDistance)
    }
}
