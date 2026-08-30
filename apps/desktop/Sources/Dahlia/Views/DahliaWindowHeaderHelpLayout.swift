import CoreGraphics

enum DahliaWindowHeaderHelpLayout {
    static let coordinateSpaceName = "DahliaWindowHeader"
    static let windowCoordinateSpaceName = "DahliaWindowHeaderHelpWindow"
    static let spacing: CGFloat = 4

    static func verticalOffset(
        buttonMinY: CGFloat,
        helpHeight: CGFloat,
        buttonHeight: CGFloat = DahliaDesign.windowHeaderControlSize
    ) -> CGFloat {
        let distance = (buttonHeight + helpHeight) / 2 + spacing
        return buttonMinY >= helpHeight + spacing ? -distance : distance
    }

    static func origin(
        buttonFrame: CGRect,
        helpSize: CGSize,
        containerOrigin: CGPoint,
        windowBounds: CGRect
    ) -> CGPoint {
        let centeredMinX = buttonFrame.midX - containerOrigin.x - helpSize.width / 2
        return CGPoint(
            x: constrainedMinX(
                centeredMinX,
                helpWidth: helpSize.width,
                windowBounds: windowBounds
            ),
            y: buttonFrame.midY - containerOrigin.y
                + verticalOffset(buttonMinY: buttonFrame.minY, helpHeight: helpSize.height)
                - helpSize.height / 2
        )
    }

    static func horizontalOffset(
        buttonMidX: CGFloat,
        helpWidth: CGFloat,
        windowBounds: CGRect
    ) -> CGFloat {
        let centeredMinX = buttonMidX - helpWidth / 2
        return constrainedMinX(
            centeredMinX,
            helpWidth: helpWidth,
            windowBounds: windowBounds
        ) - centeredMinX
    }

    private static func constrainedMinX(
        _ centeredMinX: CGFloat,
        helpWidth: CGFloat,
        windowBounds: CGRect
    ) -> CGFloat {
        guard centeredMinX.isFinite,
              helpWidth.isFinite,
              windowBounds.minX.isFinite,
              windowBounds.width.isFinite,
              helpWidth > 0,
              windowBounds.width > 0
        else { return centeredMinX }

        let inset = DahliaDesign.windowHeaderHelpHorizontalInset
        let availableWidth = windowBounds.width - inset * 2
        guard helpWidth <= availableWidth else {
            return windowBounds.midX - helpWidth / 2
        }

        let minimumMinX = windowBounds.minX + inset
        let maximumMinX = windowBounds.maxX - inset - helpWidth
        return min(max(centeredMinX, minimumMinX), maximumMinX)
    }
}
