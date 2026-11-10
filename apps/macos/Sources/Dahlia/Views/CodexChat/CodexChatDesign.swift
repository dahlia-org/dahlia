import SwiftUI

enum CodexChatDesign {
    static let panelCornerRadius: CGFloat = 18
    static let contentHorizontalPadding: CGFloat = 16
    static let composerHorizontalPadding: CGFloat = 8
    static let composerBottomPadding: CGFloat = 8
    static let composerContentPadding: CGFloat = 6
    static let composerCornerRadius: CGFloat = 22
    static let messageCornerRadius: CGFloat = 14
    static let floatingPanelSpacing: CGFloat = 8
    static let controlSize: CGFloat = 30
    static let headerControlSize: CGFloat = 28
    static let resizeAccessibilityStep: CGFloat = 20
    static let resizeHandleOutset: CGFloat = 8
    static let resizeEdgeThickness: CGFloat = 8
    static let resizeCornerSize: CGFloat = 12
    static let attachmentThumbnailSize: CGFloat = 64
    static let messageImageSize: CGFloat = 120
    static let configurationPanelWidth: CGFloat = 176
    static let configurationPanelBaseHeight: CGFloat = 78
    static let configurationRowHeight: CGFloat = 30
    static let configurationRowSpacing: CGFloat = 2
    /// Every reasoning level Pi offers. The panel lists them all for every model, so it keeps one height; a model's
    /// unsupported ones are disabled.
    static let reasoningEfforts = ["none", "minimal", "low", CodexReasoningEffortOption.defaultValue, "high", "xhigh", "max"]
    static let modelPanelWidth: CGFloat = 216
    static let contextDividerSpacing: CGFloat = 8
    static let contextLabelHorizontalPadding: CGFloat = 8
    static let contextLabelVerticalPadding: CGFloat = 4
    static let contextLabelCornerRadius: CGFloat = 5

    static func configurationPanelHeight(effortCount: Int) -> CGFloat {
        configurationPanelBaseHeight + CGFloat(effortCount) * (configurationRowHeight + configurationRowSpacing)
    }
}
