import AppKit
import SwiftUI

struct SetupTourStepHeaderView: View {
    let step: SetupTourStep

    var body: some View {
        Group {
            if step == .vault {
                VStack(spacing: 8) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)

                    Text("Dahlia")
                        .font(.largeTitle)
                        .bold()
                        .accessibilityAddTraits(.isHeader)

                    Text(L10n.version(appVersion))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    Text(step.title)
                        .font(.largeTitle)
                        .bold()
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                    Text(step.description)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: 820)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
}
