import SwiftUI

struct CodexChatThinkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Text(L10n.chatThinking)

            if accessibilityReduceMotion {
                dots(activeIndex: nil)
            } else {
                TimelineView(.periodic(from: .now, by: 0.28)) { context in
                    dots(activeIndex: activeIndex(at: context.date))
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.chatThinking)
    }

    private func dots(activeIndex: Int?) -> some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 3, id: \.self) { index in
                let isActive = activeIndex == index
                Circle()
                    .frame(width: 4, height: 4)
                    .scaleEffect(isActive ? 1 : 0.75)
                    .opacity(activeIndex == nil || isActive ? 1 : 0.3)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: activeIndex)
        .accessibilityHidden(true)
    }

    private func activeIndex(at date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / 0.28) % 3
    }
}
