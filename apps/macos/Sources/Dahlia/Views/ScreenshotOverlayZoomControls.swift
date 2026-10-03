import SwiftUI

struct ScreenshotOverlayZoomControls: View {
    @Binding var zoom: CGFloat
    @State private var isZoomOutHovered = false
    @State private var isZoomInHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: zoomOut) {
                Label(L10n.zoomOut, systemImage: "minus")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .background(
                        isZoomOutHovered && zoom > ScreenshotOverlayZoom.minimum ? Color.black.opacity(0.08) : .clear,
                        in: .circle
                    )
            }
            .disabled(zoom <= ScreenshotOverlayZoom.minimum)
            .onHover { isZoomOutHovered = $0 }

            Text(zoom, format: .percent.precision(.fractionLength(0)))
                .font(.callout)
                .monospacedDigit()
                .frame(minWidth: 52)

            Button(action: zoomIn) {
                Label(L10n.zoomIn, systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .background(
                        isZoomInHovered && zoom < ScreenshotOverlayZoom.maximum ? Color.black.opacity(0.08) : .clear,
                        in: .circle
                    )
            }
            .disabled(zoom >= ScreenshotOverlayZoom.maximum)
            .onHover { isZoomInHovered = $0 }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.black)
        .frame(height: 44)
        .padding(.horizontal, 4)
        .background(.white, in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }

    private func zoomOut() {
        zoom = ScreenshotOverlayZoom.clamped(zoom - ScreenshotOverlayZoom.step)
    }

    private func zoomIn() {
        zoom = ScreenshotOverlayZoom.clamped(zoom + ScreenshotOverlayZoom.step)
    }
}
