import SwiftUI

struct SetupTourProgressOverlayView: View {
    let currentStep: SetupTourStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SetupTourStep.allCases) { step in
                Capsule()
                    .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.22))
                    .frame(width: step == currentStep ? 24 : 9, height: 9)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.setupProgress)
        .accessibilityValue("\(currentStep.title), \(currentStep.rawValue + 1) / \(SetupTourStep.allCases.count)")
    }
}
