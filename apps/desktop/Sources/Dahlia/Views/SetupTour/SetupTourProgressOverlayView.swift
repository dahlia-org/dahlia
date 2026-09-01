import SwiftUI

struct SetupTourProgressOverlayView: View {
    let currentStep: SetupTourStep
    let steps: [SetupTourStep]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(steps) { step in
                Capsule()
                    .fill(isCompleted(step) ? Color.accentColor : Color.secondary.opacity(0.22))
                    .frame(width: step == currentStep ? 24 : 9, height: 9)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.setupProgress)
        .accessibilityValue("\(currentStep.title), \(currentIndex + 1) / \(steps.count)")
    }

    private var currentIndex: Int {
        steps.firstIndex(of: currentStep) ?? 0
    }

    private func isCompleted(_ step: SetupTourStep) -> Bool {
        (steps.firstIndex(of: step) ?? 0) <= currentIndex
    }
}
