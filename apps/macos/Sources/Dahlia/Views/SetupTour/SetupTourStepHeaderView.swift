import SwiftUI

struct SetupTourStepHeaderView: View {
    let step: SetupTourStep

    var body: some View {
        VStack(spacing: 8) {
            Text(step.title)
                .font(.dahliaLargeTitle)
                .bold()
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(step.description)
                .font(.dahliaTitle3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 820)
    }
}
