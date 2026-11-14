import AppKit
import SwiftUI

struct MainSidebarAccountSelection {
    let connectionID: UUID?
    let isLocal: Bool
    /// Connected Databricks workspaces, each listed as its own account after the Local Account.
    var databricksAccounts: [DatabricksConnection] = []
    /// The open Databricks account; `isLocal` stays true for it, since its data is on this Mac.
    var currentDatabricksID: UUID?
}

@MainActor
final class MainSidebarAccountMenuCoordinator: NSObject {
    weak var button: NSButton?

    private var connections: [DahliaAccountConnection]
    private var currentConnectionID: UUID?
    private var isLocalAccount: Bool
    private var databricksAccounts: [DatabricksConnection] = []
    private var currentDatabricksID: UUID?
    private var onOpenSettings: (SettingsCategory?) -> Void
    private var onSelectAccount: (DahliaAccountConnection?) -> Void
    private var onSelectDatabricksAccount: (UUID) -> Void
    private var onAddAccount: () -> Void
    private var onAccountAction: () -> Void
    private var unprocessedRecordingCount: Int
    private var onShowUnprocessedRecordings: () -> Void
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    private let settings: AppSettings
    private let navigation = MainSidebarAccountMenuNavigationState()
    private var mainPanel: NSPanel?
    private var submenuPanel: NSPanel?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var typeAheadResetTask: Task<Void, Never>?
    private var typeAheadBuffer = ""

    init(
        connections: [DahliaAccountConnection],
        accountSelection: MainSidebarAccountSelection,
        onOpenSettings: @escaping (SettingsCategory?) -> Void,
        onSelectAccount: @escaping (DahliaAccountConnection?) -> Void,
        onSelectDatabricksAccount: @escaping (UUID) -> Void = { _ in },
        onAddAccount: @escaping () -> Void = {},
        onAccountAction: @escaping () -> Void,
        unprocessedRecordingCount: Int = 0,
        onShowUnprocessedRecordings: @escaping () -> Void,
        settings: AppSettings = .shared
    ) {
        self.settings = settings
        self.connections = connections
        currentConnectionID = accountSelection.connectionID
        isLocalAccount = accountSelection.isLocal
        databricksAccounts = accountSelection.databricksAccounts
        currentDatabricksID = accountSelection.currentDatabricksID
        self.onOpenSettings = onOpenSettings
        self.onSelectAccount = onSelectAccount
        self.onSelectDatabricksAccount = onSelectDatabricksAccount
        self.onAddAccount = onAddAccount
        self.onAccountAction = onAccountAction
        self.unprocessedRecordingCount = unprocessedRecordingCount
        self.onShowUnprocessedRecordings = onShowUnprocessedRecordings
    }

    static func shouldPassThroughKeyEvent(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        !modifierFlags.isDisjoint(with: [.command, .control])
    }

    func update(
        connections: [DahliaAccountConnection],
        accountSelection: MainSidebarAccountSelection,
        onOpenSettings: @escaping (SettingsCategory?) -> Void,
        onSelectAccount: @escaping (DahliaAccountConnection?) -> Void,
        onSelectDatabricksAccount: @escaping (UUID) -> Void = { _ in },
        onAddAccount: @escaping () -> Void = {},
        onAccountAction: @escaping () -> Void,
        unprocessedRecordingCount: Int = 0,
        onShowUnprocessedRecordings: @escaping () -> Void
    ) {
        self.connections = connections
        currentConnectionID = accountSelection.connectionID
        isLocalAccount = accountSelection.isLocal
        databricksAccounts = accountSelection.databricksAccounts
        currentDatabricksID = accountSelection.currentDatabricksID
        self.onOpenSettings = onOpenSettings
        self.onSelectAccount = onSelectAccount
        self.onSelectDatabricksAccount = onSelectDatabricksAccount
        self.onAddAccount = onAddAccount
        self.onAccountAction = onAccountAction
        self.unprocessedRecordingCount = unprocessedRecordingCount
        self.onShowUnprocessedRecordings = onShowUnprocessedRecordings
    }

    @objc
    func toggleMenu() {
        if mainPanel == nil {
            presentMainMenu()
        } else {
            dismissMenu()
        }
    }

    func dismissMenu() {
        stopMonitoring()
        closeSubmenu()
        closePanel(&mainPanel)
        navigation.reset()
    }

    private func presentMainMenu() {
        guard let button else { return }

        navigation.reset()
        let content = MainSidebarAccountMenuPanel(width: MainSidebarAccountMenuLayout.rootMenuWidth) {
            MainSidebarAccountRootMenuView(
                navigation: navigation,
                connections: connections,
                currentConnectionID: currentConnectionID,
                isLocalAccount: isLocalAccount,
                showsLocalAccount: !settings.hideLocalAccount,
                showsAddAccount: showsAddAccount,
                showsAccountAction: showsAccountAction,
                databricksAccounts: databricksAccounts,
                currentDatabricksID: currentDatabricksID,
                onShowAppearance: { [weak self] in self?.presentAppearanceMenu(anchorMinY: $0) },
                onShowLanguages: { [weak self] in self?.presentLanguageMenu(anchorMinY: $0) },
                onShowAccountDetails: { [weak self] connection, minY in
                    self?.presentAccountDetails(connection, anchorMinY: minY)
                },
                onDismissSubmenu: { [weak self] in self?.closeSubmenu() },
                onOpenSettings: { [weak self] in self?.openSettings(category: $0) },
                onSelectAccount: { [weak self] in self?.selectAccount($0) },
                onSelectDatabricksAccount: { [weak self] in self?.selectDatabricksAccount($0) },
                onAddAccount: { [weak self] in self?.addAccount() },
                onAccountAction: { [weak self] in self?.performAccountAction() },
                unprocessedRecordingCount: unprocessedRecordingCount,
                onShowUnprocessedRecordings: { [weak self] in self?.showUnprocessedRecordings() }
            )
        }
        let panel = makePanel(content: content)
        positionMainPanel(panel, relativeTo: button)
        attach(panel, to: button.window)
        mainPanel = panel
        startMonitoring()
    }

    private func presentAccountDetails(_ connection: DahliaAccountConnection, anchorMinY: CGFloat? = nil) {
        let content = MainSidebarAccountMenuPanel(width: 320) {
            SyncProgressView(connection: connection, navigation: navigation, openURL: openURL)
        }
        presentSubmenu(content, menu: .accountDetails, anchorMinY: anchorMinY)
    }

    private func presentLanguageMenu(anchorMinY: CGFloat? = nil) {
        let content = MainSidebarAccountMenuPanel(width: MainSidebarAccountMenuLayout.menuWidth) {
            MainSidebarAccountLanguageMenuView(
                navigation: navigation,
                onSelectLanguage: { [weak self] in self?.dismissMenu() }
            )
        }
        presentSubmenu(content, menu: .languages, anchorMinY: anchorMinY)
    }

    private func presentAppearanceMenu(anchorMinY: CGFloat? = nil) {
        let content = MainSidebarAccountMenuPanel(width: MainSidebarAccountMenuLayout.menuWidth) {
            MainSidebarAccountAppearanceMenuView(
                navigation: navigation,
                onSelectAppearance: { [weak self] in self?.dismissMenu() },
                settings: settings
            )
        }
        presentSubmenu(content, menu: .appearance, anchorMinY: anchorMinY)
    }

    private func presentSubmenu(
        _ content: some View,
        menu: MainSidebarAccountMenuNavigationState.ActiveMenu,
        anchorMinY: CGFloat?
    ) {
        guard let mainPanel else { return }
        resetTypeAhead()
        closePanel(&submenuPanel)
        navigation.showSubmenu(menu)

        let panel = makePanel(content: content)
        positionSubmenu(panel, relativeTo: mainPanel, anchorMinY: anchorMinY)
        attach(panel, to: button?.window)
        submenuPanel = panel
        announce(menu == .accountDetails ? L10n.syncProgress : menu == .appearance ? L10n.appearance : L10n.language)
    }

    private func makePanel(content: some View) -> NSPanel {
        let hostingView = NSHostingView(rootView: content.fixedSize().dahliaAppearance())
        hostingView.frame.size = hostingView.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle]
        return panel
    }

    private func positionMainPanel(_ panel: NSPanel, relativeTo button: NSButton) {
        guard let window = button.window else { return }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screenFrame = visibleScreenFrame(containing: buttonFrame)
        panel.setFrameOrigin(MainSidebarAccountMenuLayout.mainMenuOrigin(
            panelSize: panel.frame.size,
            buttonFrame: buttonFrame,
            screenFrame: screenFrame
        ))
    }

    private func positionSubmenu(_ panel: NSPanel, relativeTo mainPanel: NSPanel, anchorMinY: CGFloat?) {
        let screenFrame = visibleScreenFrame(containing: mainPanel.frame)
        let mouseLocation = NSEvent.mouseLocation
        let fallbackAnchorY = mainPanel.frame.contains(mouseLocation)
            ? mouseLocation.y + MainSidebarAccountMenuLayout.menuRowHeight / 2
            : nil
        let anchorY = anchorMinY.map { MainSidebarAccountMenuLayout.submenuAnchorY(rowMinY: $0, mainPanelFrame: mainPanel.frame) }
            ?? fallbackAnchorY
        panel.setFrameOrigin(MainSidebarAccountMenuLayout.submenuOrigin(
            panelSize: panel.frame.size,
            mainPanelFrame: mainPanel.frame,
            screenFrame: screenFrame,
            anchorY: anchorY
        ))
    }

    private func visibleScreenFrame(containing targetFrame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        if let index = MainSidebarAccountMenuLayout.screenIndex(
            containing: targetFrame,
            screenFrames: screens.map(\.frame)
        ) {
            return screens[index].visibleFrame
        }
        return button?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    }

    private func attach(_ panel: NSPanel, to parentWindow: NSWindow?) {
        if let parentWindow {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    private func openSettings(category: SettingsCategory? = nil) {
        dismissMenu()
        onOpenSettings(category)
    }

    private func showUnprocessedRecordings() {
        dismissMenu()
        onShowUnprocessedRecordings()
    }

    private func addAccount() {
        dismissMenu()
        onAddAccount()
    }

    private func performAccountAction() {
        dismissMenu()
        onAccountAction()
    }

    private func selectAccount(_ connection: DahliaAccountConnection?) {
        dismissMenu()
        guard connection?.id != currentConnectionID || (connection == nil && currentDatabricksID != nil) else { return }
        onSelectAccount(connection)
    }

    private func selectDatabricksAccount(_ id: UUID) {
        dismissMenu()
        guard id != currentDatabricksID else { return }
        onSelectDatabricksAccount(id)
    }

    private func closeSubmenu() {
        resetTypeAhead()
        closePanel(&submenuPanel)
        navigation.returnToRoot()
    }

    private func closePanel(_ panel: inout NSPanel?) {
        guard let openPanel = panel else { return }
        openPanel.parent?.removeChildWindow(openPanel)
        openPanel.close()
        panel = nil
    }

    private func startMonitoring() {
        let localEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: localEvents) { [weak self] event in
            guard let self else { return event }
            return handleLocalEvent(event)
        }
        let globalEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: globalEvents) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissMenu()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown {
            return handleKeyDown(event)
        }
        guard event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown else { return event }

        let location = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        guard !contains(location) else { return event }
        dismissMenu()
        return event
    }

    @objc
    private func applicationDidResignActive() {
        dismissMenu()
    }

    private func contains(_ screenPoint: NSPoint) -> Bool {
        if mainPanel?.frame.contains(screenPoint) == true || submenuPanel?.frame.contains(screenPoint) == true {
            return true
        }
        guard let button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(screenPoint)
    }

    private func stopMonitoring() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }
}

extension MainSidebarAccountMenuCoordinator {
    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if Self.shouldPassThroughKeyEvent(modifierFlags: event.modifierFlags) {
            dismissMenu()
            return event
        }

        if navigation.activeMenu == .accountDetails {
            switch event.keyCode {
            case 53:
                dismissMenu()
            case 123:
                closeSubmenu()
            case 36, 76:
                openSelectedAccountOnServer()
            case 49 where !event.modifierFlags.contains(.shift):
                openSelectedAccountOnServer()
            default:
                scrollAccountDetails(event)
            }
            return nil
        }
        switch event.keyCode {
        case 53:
            dismissMenu()
        case 48:
            moveSelection(event.modifierFlags.contains(.shift) ? -1 : 1)
        case 125:
            moveSelection(1)
        case 126:
            moveSelection(-1)
        case 123:
            if navigation.activeMenu != .root {
                closeSubmenu()
            }
        case 124:
            openSelectedSubmenu()
        case 36, 49, 76:
            activateSelection()
        default:
            handleTypeAhead(event)
        }
        return nil
    }

    /// These non-key panels must route scrolling explicitly instead of returning keys to the parent window.
    private func scrollAccountDetails(_ event: NSEvent) {
        func findScrollView(in view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
        }
        guard let content = submenuPanel?.contentView, let scroll = findScrollView(in: content) else { return }
        let clip = scroll.contentView
        var bounds = clip.bounds
        let direction: CGFloat = clip.isFlipped ? 1 : -1
        let page = max(scroll.verticalLineScroll, bounds.height - scroll.verticalPageScroll)
        switch event.keyCode {
        case 125: bounds.origin.y += direction * scroll.verticalLineScroll
        case 126: bounds.origin.y -= direction * scroll.verticalLineScroll
        case 121: bounds.origin.y += direction * page
        case 116: bounds.origin.y -= direction * page
        case 115: bounds.origin.y = clip.isFlipped ? clip.documentRect.minY : clip.documentRect.maxY
        case 119: bounds.origin.y = clip.isFlipped ? clip.documentRect.maxY : clip.documentRect.minY
        case 49:
            bounds.origin.y += direction * page * (event.modifierFlags.contains(.shift) ? -1 : 1)
        default: return
        }
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func openSelectedAccountOnServer() {
        guard let selection = navigation.rootSelection,
              connections.indices.contains(selection),
              let url = SyncServerLink.url(origin: connections[selection].origin) else { return }
        let presentationID = navigation.accountDetailPresentationID
        guard openURL(url) else {
            navigation.publishAccountDetailError(L10n.syncOpenServerFailed, for: presentationID)
            announce(L10n.syncOpenServerFailed)
            return
        }
        navigation.publishAccountDetailError(nil, for: presentationID)
    }

    func handleTypeAhead(_ event: NSEvent) {
        guard navigation.activeMenu != .root,
              let input = event.charactersIgnoringModifiers,
              !input.isEmpty,
              input.rangeOfCharacter(from: .controlCharacters) == nil else { return }

        let combinedInput = typeAheadBuffer + input
        if selectTypeAheadMatch(for: combinedInput) {
            typeAheadBuffer = combinedInput
        } else if selectTypeAheadMatch(for: input) {
            typeAheadBuffer = input
        } else {
            typeAheadBuffer = ""
        }
        scheduleTypeAheadReset()
    }

    func selectTypeAheadMatch(for prefix: String) -> Bool {
        let titles: [String]
        let isEnabled: (Int) -> Bool
        switch navigation.activeMenu {
        case .root, .accountDetails:
            return false
        case .appearance:
            let appearances = AppAppearance.allCases
            titles = appearances.map(\.displayName)
            isEnabled = { index in appearances[index] != self.settings.appAppearance }
        case .languages:
            let languages = AppLanguage.allCases
            titles = languages.map(\.displayName)
            isEnabled = { index in languages[index] != AppSettings.shared.appLanguage }
        }
        guard let match = MainSidebarAccountMenuNavigationState.firstEnabledIndex(
            matching: prefix,
            titles: titles,
            isEnabled: isEnabled
        ) else { return false }
        navigation.submenuSelection = match
        announceCurrentSelection()
        return true
    }

    func scheduleTypeAheadReset() {
        typeAheadResetTask?.cancel()
        typeAheadResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.typeAheadBuffer = ""
            self?.typeAheadResetTask = nil
        }
    }

    func resetTypeAhead() {
        typeAheadResetTask?.cancel()
        typeAheadResetTask = nil
        typeAheadBuffer = ""
    }

    func moveSelection(_ direction: Int) {
        switch navigation.activeMenu {
        case .root:
            navigation.rootSelection = MainSidebarAccountMenuNavigationState.nextEnabledIndex(
                from: navigation.rootSelection,
                direction: direction,
                count: menuOffset + (showsAccountAction ? 5 : 4),
                isEnabled: isRootIndexEnabled
            )
        case .accountDetails:
            return
        case .appearance:
            let appearances = AppAppearance.allCases
            navigation.submenuSelection = MainSidebarAccountMenuNavigationState.nextEnabledIndex(
                from: navigation.submenuSelection,
                direction: direction,
                count: appearances.count,
                isEnabled: { appearances[$0] != settings.appAppearance }
            )
        case .languages:
            let languages = AppLanguage.allCases
            let currentLanguage = AppSettings.shared.appLanguage
            navigation.submenuSelection = MainSidebarAccountMenuNavigationState.nextEnabledIndex(
                from: navigation.submenuSelection,
                direction: direction,
                count: languages.count,
                isEnabled: { languages[$0] != currentLanguage }
            )
        }
        announceCurrentSelection()
    }

    func openSelectedSubmenu() {
        guard navigation.activeMenu == .root, let selection = navigation.rootSelection else { return }
        if connections.indices.contains(selection) { presentAccountDetails(connections[selection]) }
        if selection == menuOffset { presentLanguageMenu() }
        if selection == menuOffset + 1 { presentAppearanceMenu() }
    }

    func activateSelection() {
        switch navigation.activeMenu {
        case .root: activateRootSelection()
        case .languages: activateLanguageSelection()
        case .appearance: activateAppearanceSelection()
        case .accountDetails: break
        }
    }

    func activateRootSelection() {
        guard let selection = navigation.rootSelection else { return }
        if connections.indices.contains(selection) {
            guard connections[selection].workspaceCount > 0 else { return }
            selectAccount(connections[selection])
            return
        }
        if databricksIndices.contains(selection) {
            selectDatabricksAccount(databricksAccounts[selection - databricksIndices.lowerBound].id)
            return
        }
        if !settings.hideLocalAccount, selection == connections.count {
            // Choosing the Local Account opens its `Default` workspace when it has none.
            selectAccount(nil)
            return
        }
        if showsAddAccount, selection == menuOffset - 1 {
            addAccount()
            return
        }
        switch selection - menuOffset {
        case 0: presentLanguageMenu()
        case 1: presentAppearanceMenu()
        case 2: openSettings(category: nil)
        case 3: showUnprocessedRecordings()
        case 4 where showsAccountAction: performAccountAction()
        default: break
        }
    }

    func activateLanguageSelection() {
        guard let selection = navigation.submenuSelection,
              AppLanguage.allCases.indices.contains(selection) else { return }
        let language = AppLanguage.allCases[selection]
        guard language != AppSettings.shared.appLanguage else { return }
        AppSettings.shared.appLanguage = language
        dismissMenu()
    }

    func activateAppearanceSelection() {
        guard let selection = navigation.submenuSelection,
              AppAppearance.allCases.indices.contains(selection) else { return }
        let appearance = AppAppearance.allCases[selection]
        guard appearance != settings.appAppearance else { return }
        settings.appAppearance = appearance
        dismissMenu()
    }

    func announceCurrentSelection() {
        let title: String?
        switch navigation.activeMenu {
        case .root:
            var titles = connections.map(\.displayName)
            if !settings.hideLocalAccount { titles.append(L10n.localAccount) }
            titles += databricksAccounts.map { L10n.unityGatewayHost($0.hostName) }
            if showsAddAccount { titles.append(L10n.addAccount) }
            titles += [L10n.language, L10n.appearance, L10n.settings, L10n.unprocessedRecordings]
            if showsAccountAction {
                titles.append(hasCurrentConnection || currentDatabricksID != nil ? L10n.signOut : L10n.dahliaSignIn)
            }
            title = navigation.rootSelection.flatMap { titles.indices.contains($0) ? titles[$0] : nil }
        case .appearance:
            title = navigation.submenuSelection.flatMap {
                AppAppearance.allCases.indices.contains($0) ? AppAppearance.allCases[$0].displayName : nil
            }
        case .accountDetails:
            title = L10n.syncProgress
        case .languages:
            title = navigation.submenuSelection.flatMap {
                AppLanguage.allCases.indices.contains($0) ? AppLanguage.allCases[$0].displayName : nil
            }
        }
        guard let title else { return }
        announce(title)
    }

    func announce(_ message: String) {
        guard let panel = submenuPanel ?? mainPanel else { return }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    var hasCurrentConnection: Bool {
        connections.contains { $0.id == currentConnectionID }
    }

    var showsAddAccount: Bool { !connections.isEmpty || !databricksAccounts.isEmpty }
    var showsAccountAction: Bool { hasCurrentConnection || currentDatabricksID != nil || !showsAddAccount }
    var menuOffset: Int { databricksStartIndex + databricksAccounts.count + (showsAddAccount ? 1 : 0) }
    private var databricksStartIndex: Int { connections.count + (settings.hideLocalAccount ? 0 : 1) }
    /// Databricks accounts follow the Local Account and create their first workspace when chosen.
    private var databricksIndices: Range<Int> { databricksStartIndex ..< databricksStartIndex + databricksAccounts.count }

    private func isRootIndexEnabled(_ index: Int) -> Bool {
        if connections.indices.contains(index) { return connections[index].workspaceCount > 0 }
        return true
    }

}
