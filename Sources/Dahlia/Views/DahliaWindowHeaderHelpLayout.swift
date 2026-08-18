import CoreGraphics

enum DahliaWindowHeaderHelpLayout {
    static let coordinateSpaceName = "DahliaWindowHeader"
    static let spacing: CGFloat = 4

    static func verticalOffset(
        buttonMinY: CGFloat,
        helpHeight: CGFloat
    ) -> CGFloat {
        let distance = (DahliaDesign.windowHeaderControlSize + helpHeight) / 2 + spacing
        return buttonMinY >= helpHeight + spacing ? -distance : distance
    }

    static func unconstrainedOrigin(
        buttonFrame: CGRect,
        helpSize: CGSize,
        containerOrigin: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: buttonFrame.midX - containerOrigin.x - helpSize.width / 2,
            y: buttonFrame.midY - containerOrigin.y
                + verticalOffset(buttonMinY: buttonFrame.minY, helpHeight: helpSize.height)
                - helpSize.height / 2
        )
    }

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
