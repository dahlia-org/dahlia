import CoreGraphics

enum DahliaWindowHeaderHelpLayout {
    static let coordinateSpaceName = "DahliaWindowHeader"

    static func horizontalOffset(
        buttonMidX: CGFloat,
        helpWidth: CGFloat,
        containerWidth: CGFloat
    ) -> CGFloat {
        guard buttonMidX.isFinite,
              helpWidth.isFinite,
              containerWidth.isFinite,
              helpWidth > 0,
              containerWidth > 0
        else { return 0 }

        let inset = DahliaDesign.windowHeaderHelpHorizontalInset
        let centeredMinX = buttonMidX - helpWidth / 2
        let availableWidth = containerWidth - inset * 2
        guard helpWidth <= availableWidth else {
            return containerWidth / 2 - buttonMidX
        }

        let maximumMinX = containerWidth - inset - helpWidth
        let clampedMinX = min(max(centeredMinX, inset), maximumMinX)
        return clampedMinX - centeredMinX
    }
}
