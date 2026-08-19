import AppKit
import CoreGraphics
import Foundation

/// MainActor 上で画像全体を比較せず、Data の backing storage から変更を識別する。
///
/// Data を保持するため、旧 storage の解放後に同じアドレスが再利用されても false-equal にはならない。
/// 同じ内容の別 storage は保守的に変更として扱い、stale thumbnail を避ける。
struct ScreenshotImageContentIdentity: Equatable {
    private static let maximumDirectComparisonByteCount = 64

    private let imageData: Data
    private let mimeType: String

    init(_ screenshot: MeetingScreenshotRecord) {
        imageData = screenshot.imageData
        mimeType = screenshot.mimeType
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.mimeType == rhs.mimeType,
              lhs.imageData.count == rhs.imageData.count else { return false }
        if lhs.imageData.count <= maximumDirectComparisonByteCount {
            return lhs.imageData == rhs.imageData
        }
        return lhs.imageData.withUnsafeBytes { lhsBytes in
            rhs.imageData.withUnsafeBytes { rhsBytes in
                lhsBytes.baseAddress == rhsBytes.baseAddress
            }
        }
    }
}

@MainActor
private final class PassthroughImageView: NSImageView {
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class ScreenshotThumbnailButton: NSButton {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
    }

    func updateBackgroundColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        }
    }
}

@MainActor
final class ScreenshotCollectionViewItem: NSCollectionViewItem {
    typealias ThumbnailProvider = @Sendable (UUID, Data, Int) async -> CGImage?

    private enum ThumbnailLoadState {
        case idle
        case loading
        case loaded
        case failed
    }

    struct Configuration {
        let screenshot: MeetingScreenshotRecord
        let timestamp: String
        let isSelecting: Bool
        let isSelected: Bool
        let isReferencedBySummary: Bool
        let isDeletionDisabled: Bool
    }

    struct Actions {
        let activate: (CGImage?) -> Void
        let copy: () -> Void
        let download: () -> Void
        let delete: () -> Void
    }

    struct RenderedState: Equatable {
        let isThumbnailEnabled: Bool
        let isLockVisible: Bool
        let selectionSymbolName: String?
        let isCopyHidden: Bool
        let isDeleteHidden: Bool
        let isDeleteEnabled: Bool
    }

    nonisolated static let reuseIdentifier = NSUserInterfaceItemIdentifier("ScreenshotCollectionViewItem")

    private let thumbnailButton = ScreenshotThumbnailButton()
    private let timestampLabel = NSTextField(labelWithString: "")
    private let lockImageView = NSImageView()
    private let selectionImageView = PassthroughImageView()
    private let copyButton = NSButton()
    private let downloadButton = NSButton()
    private let deleteButton = NSButton()
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailLoadState = ThumbnailLoadState.idle
    private var loadGeneration: UInt64 = 0
    private var activationHandler: ((CGImage?) -> Void)?
    private var copyHandler: (() -> Void)?
    private var downloadHandler: (() -> Void)?
    private var deleteHandler: (() -> Void)?
    private var representedImageIdentity: ScreenshotImageContentIdentity?
    private var loadedThumbnailImage: CGImage?

    private(set) var representedScreenshotID: UUID?
    private(set) var renderedState: RenderedState?
    var loadedThumbnailSize: NSSize? { thumbnailButton.image?.size }
    var isLoadingThumbnail: Bool { thumbnailTask != nil }
    var hasCallbacks: Bool {
        activationHandler != nil || copyHandler != nil || downloadHandler != nil || deleteHandler != nil
    }

    var selectionIndicatorAcceptsHitTesting: Bool { selectionImageView.hitTest(.zero) != nil }
    var selectionIndicatorIsAccessibilityElement: Bool { selectionImageView.isAccessibilityElement() }

    override func loadView() {
        let rootView = NSBox()
        rootView.boxType = .custom
        rootView.borderWidth = 0
        rootView.cornerRadius = DahliaDesign.Media.cornerRadius
        rootView.fillColor = NSColor.labelColor.withAlphaComponent(0.05)
        rootView.contentViewMargins = NSSize(width: 6, height: 6)

        configureThumbnailButton()
        configureMetadataControls()

        let metadataStack = NSStackView(views: [timestampLabel, lockImageView, copyButton, downloadButton, deleteButton])
        metadataStack.orientation = .horizontal
        metadataStack.alignment = .centerY
        metadataStack.spacing = 6
        timestampLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timestampLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let contentStack = NSStackView(views: [thumbnailButton, metadataStack])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 4
        contentStack.distribution = .fill

        selectionImageView.translatesAutoresizingMaskIntoConstraints = false
        selectionImageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        selectionImageView.setAccessibilityElement(false)

        rootView.addSubview(contentStack)
        rootView.addSubview(selectionImageView)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 6),
            contentStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -6),
            contentStack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 6),
            contentStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -6),
            thumbnailButton.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            thumbnailButton.heightAnchor.constraint(equalTo: thumbnailButton.widthAnchor, multiplier: 9 / 16),
            metadataStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            selectionImageView.topAnchor.constraint(equalTo: thumbnailButton.topAnchor, constant: 8),
            selectionImageView.trailingAnchor.constraint(equalTo: thumbnailButton.trailingAnchor, constant: -8),
        ])
        view = rootView
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        releaseRepresentedContent()
    }

    func didEndDisplaying() {
        releaseRepresentedContent()
    }

    private func releaseRepresentedContent() {
        releaseThumbnail()
        representedScreenshotID = nil
        representedImageIdentity = nil
        renderedState = nil
        activationHandler = nil
        copyHandler = nil
        downloadHandler = nil
        deleteHandler = nil
        timestampLabel.stringValue = ""
        lockImageView.isHidden = true
        selectionImageView.isHidden = true
        selectionImageView.image = nil
    }

    func configure(
        _ configuration: Configuration,
        thumbnailProvider: @escaping ThumbnailProvider = defaultThumbnailProvider,
        actions: Actions
    ) {
        loadViewIfNeeded()
        let screenshot = configuration.screenshot
        let imageIdentity = ScreenshotImageContentIdentity(screenshot)
        let shouldStartThumbnailLoad = representedScreenshotID != screenshot.id
            || representedImageIdentity != imageIdentity
            || thumbnailLoadState == .idle
        representedScreenshotID = screenshot.id
        representedImageIdentity = imageIdentity
        timestampLabel.stringValue = configuration.timestamp
        timestampLabel.toolTip = configuration.timestamp
        timestampLabel.font = .preferredFont(forTextStyle: .caption1)
        activationHandler = actions.activate
        copyHandler = actions.copy
        downloadHandler = actions.download
        deleteHandler = actions.delete

        thumbnailButton.isEnabled = !configuration.isSelecting || !configuration.isReferencedBySummary
        let accessibilityLabel = if configuration.isSelecting, configuration.isReferencedBySummary {
            L10n.screenshotUsedInSummary
        } else if configuration.isSelecting {
            L10n.select
        } else {
            L10n.open
        }
        thumbnailButton.setAccessibilityLabel(accessibilityLabel)
        thumbnailButton.setAccessibilityValue(configuration.isSelected ? L10n.selected : "")

        lockImageView.isHidden = !configuration.isReferencedBySummary
        selectionImageView.isHidden = !configuration.isSelecting
        var selectionSymbolName: String?
        if configuration.isSelecting {
            let symbolName = if configuration.isReferencedBySummary {
                "lock.circle.fill"
            } else if configuration.isSelected {
                "checkmark.circle.fill"
            } else {
                "circle"
            }
            selectionSymbolName = symbolName
            selectionImageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            selectionImageView.contentTintColor = configuration.isReferencedBySummary || !configuration.isSelected
                ? .secondaryLabelColor
                : .controlAccentColor
        }

        copyButton.isHidden = configuration.isSelecting
        downloadButton.isHidden = configuration.isSelecting
        deleteButton.isHidden = configuration.isSelecting
        deleteButton.isEnabled = !configuration.isReferencedBySummary && !configuration.isDeletionDisabled
        deleteButton.toolTip = configuration.isReferencedBySummary ? L10n.screenshotUsedInSummary : L10n.delete
        renderedState = RenderedState(
            isThumbnailEnabled: thumbnailButton.isEnabled,
            isLockVisible: !lockImageView.isHidden,
            selectionSymbolName: selectionSymbolName,
            isCopyHidden: copyButton.isHidden,
            isDeleteHidden: deleteButton.isHidden,
            isDeleteEnabled: deleteButton.isEnabled
        )
        if shouldStartThumbnailLoad {
            startThumbnailLoad(for: screenshot, provider: thumbnailProvider)
        }
    }

    private func releaseThumbnail() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        thumbnailLoadState = .idle
        loadGeneration &+= 1
        loadedThumbnailImage = nil
        thumbnailButton.image = nil
    }

    private func configureThumbnailButton() {
        thumbnailButton.translatesAutoresizingMaskIntoConstraints = false
        thumbnailButton.isBordered = false
        thumbnailButton.imagePosition = .imageOnly
        thumbnailButton.imageScaling = .scaleProportionallyUpOrDown
        thumbnailButton.target = self
        thumbnailButton.action = #selector(activateThumbnail)
        thumbnailButton.wantsLayer = true
        thumbnailButton.layer?.cornerRadius = DahliaDesign.Highlight.compactCornerRadius
        thumbnailButton.layer?.masksToBounds = true
        thumbnailButton.updateBackgroundColor()
        configureContextMenu()
    }

    private func configureMetadataControls() {
        timestampLabel.font = .preferredFont(forTextStyle: .caption1)
        timestampLabel.textColor = DahliaDesign.secondaryTextNSColor
        timestampLabel.lineBreakMode = .byTruncatingTail

        lockImageView.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: L10n.screenshotUsedInSummary)
        lockImageView.contentTintColor = .secondaryLabelColor
        lockImageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)

        configureIconButton(copyButton, symbolName: "doc.on.doc", label: L10n.copyImage, action: #selector(copyScreenshot))
        configureIconButton(downloadButton, symbolName: "arrow.down.circle", label: L10n.download, action: #selector(downloadScreenshot))
        configureIconButton(deleteButton, symbolName: "trash", label: L10n.delete, action: #selector(deleteScreenshot))
        deleteButton.contentTintColor = .secondaryLabelColor
    }

    private func configureIconButton(_ button: NSButton, symbolName: String, label: String, action: Selector) {
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func configureContextMenu() {
        let menu = NSMenu()
        let copyItem = NSMenuItem(
            title: L10n.copyImage,
            action: #selector(copyScreenshot),
            keyEquivalent: ""
        )
        copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L10n.copyImage)
        copyItem.target = self
        menu.addItem(copyItem)
        thumbnailButton.menu = menu
    }

    private func startThumbnailLoad(for screenshot: MeetingScreenshotRecord, provider: @escaping ThumbnailProvider) {
        releaseThumbnail()
        thumbnailLoadState = .loading
        let generation = loadGeneration
        let screenshotID = screenshot.id
        thumbnailTask = Task { [weak self] in
            let image = await provider(
                screenshotID,
                screenshot.imageData,
                ScreenshotGridSizing.maximumThumbnailPixelSize
            )
            guard let self,
                  self.loadGeneration == generation,
                  self.representedScreenshotID == screenshotID else { return }
            self.thumbnailTask = nil
            guard !Task.isCancelled else { return }
            guard let image else {
                self.thumbnailLoadState = .failed
                return
            }
            self.thumbnailLoadState = .loaded
            self.loadedThumbnailImage = image
            self.thumbnailButton.image = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
        }
    }

    private static let defaultThumbnailProvider: ThumbnailProvider = { screenshotID, data, maxPixelSize in
        await ScreenshotImageLoader.shared.image(
            screenshotID: screenshotID,
            data: data,
            maxPixelSize: maxPixelSize
        )
    }

    @objc private func activateThumbnail() {
        activationHandler?(loadedThumbnailImage)
    }

    @objc private func copyScreenshot() {
        copyHandler?()
    }

    @objc private func downloadScreenshot() {
        downloadHandler?()
    }

    @objc private func deleteScreenshot() {
        deleteHandler?()
    }
}
