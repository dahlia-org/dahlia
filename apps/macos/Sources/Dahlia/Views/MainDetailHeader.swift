import DahliaRuntimeSupport
import SwiftUI

struct MainDetailHeader<NavigationContent: View>: View {
    @State private var helpBounds: CGRect = .zero

    var reservesChatControl = true
    let leadingInset: CGFloat
    let syncState: MeetingSyncState?
    let textContentState: TextContentAvailability.State?
    let retryTextContent: () -> Void
    @ViewBuilder let navigationContent: NavigationContent

    var body: some View {
        DahliaWindowHeader {
            navigationContent
            if let textContentState, textContentState != .ready {
                TextContentStatusView(state: textContentState, retry: retryTextContent)
                    .lineLimit(1)
                    .frame(maxWidth: 180)
            }
            Group {
                if let syncState {
                    MeetingSyncStatusView(state: syncState, helpBounds: helpBounds)
                } else {
                    Color.clear.accessibilityHidden(true)
                }
            }
            .frame(width: DahliaDesign.windowHeaderControlSize)
            if reservesChatControl {
                Color.clear
                    .frame(width: DahliaDesign.windowHeaderControlSize)
                    .accessibilityHidden(true)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { helpBounds = $0 }
        .padding(.leading, leadingInset)
    }
}
