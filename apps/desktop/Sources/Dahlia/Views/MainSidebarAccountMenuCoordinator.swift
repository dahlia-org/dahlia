import AppKit
import SwiftUI

@MainActor
final class MainSidebarAccountMenuCoordinator: NSObject {
    weak var button: NSButton?

    private var vaults: [VaultRecord]
    private var currentVault: VaultRecord?
    private var account: DahliaCloudAccount?
    private var accountOrigin: String?
    private var isCloudAccount: Bool?
    private var onSelectVault: (VaultRecord) -> Void
    private var onManageVaults: () -> Void
    private var onOpenSettings: (SettingsCategory?) -> Void
    private var onAccountAction: () -> Void
    private let navigation = MainSidebarAccountMenuNavigationState()
    private var mainPanel: NSPanel?
    private var submenuPanel: NSPanel?
    private var accountHelpPanel: NSPanel?
    private var accountHelpTask: Task<Void, Never>?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var typeAheadResetTask: Task<Void, Never>?
    private var typeAheadBuffer = ""

    init(
        vaults: [VaultRecord],
        currentVault: VaultRecord?,
        account: DahliaCloudAccount?,
        accountOrigin: String?,
        isCloudAccount: Bool?,
        onSelectVault: @escaping (VaultRecord) -> Void,
        onManageVaults: @escaping () -> Void,
        onOpenSettings: @escaping (SettingsCategory?) -> Void,
        onAccountAction: @escaping () -> Void
    ) {
        self.vaults = vaults
        self.currentVault = currentVault
        self.account = account
        self.accountOrigin = accountOrigin
        self.isCloudAccount = isCloudAccount
        self.onSelectVault = onSelectVault
        self.onManageVaults = onManageVaults
        self.onOpenSettings = onOpenSettings
        self.onAccountAction = onAccountAction
    }

    static func shouldPassThroughKeyEvent(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        !modifierFlags.isDisjoint(with: [.command, .control])
    }

    func update(
        vaults: [VaultRecord],
        currentVault: VaultRecord?,
        account: DahliaCloudAccount?,
        accountOrigin: String?,
        isCloudAccount: Bool?,
        onSelectVault: @escaping (VaultRecord) -> Void,
        onManageVaults: @escaping () -> Void,
        onOpenSettings: @escaping (SettingsCategory?) -> Void,
        onAccountAction: @escaping () -> Void
    ) {
        let refreshVaultMenu = navigation.activeMenu == .vaults &&
            (self.vaults != vaults || self.currentVault != currentVault)
        self.vaults = vaults
        self.currentVault = currentVault
        self.account = account
        self.accountOrigin = accountOrigin
        self.isCloudAccount = isCloudAccount
        self.onSelectVault = onSelectVault
        self.onManageVaults = onManageVaults
        self.onOpenSettings = onOpenSettings
        self.onAccountAction = onAccountAction
        if refreshVaultMenu {
            presentVaultMenu()
        }
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
        dismissAccountHelp()
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
                account: account,
                accountOrigin: accountOrigin,
                isCloudAccount: isCloudAccount,
                onShowVaults: { [weak self] in self?.presentVaultMenu(anchorMinY: $0) },
                onShowLanguages: { [weak self] in self?.presentLanguageMenu(anchorMinY: $0) },
                onDismissSubmenu: { [weak self] in self?.closeSubmenu() },
                onShowAccountHelp: { [weak self] label, frame in self?.scheduleAccountHelp(label: label, rowFrame: frame) },
                onDismissAccountHelp: { [weak self] in self?.dismissAccountHelp() },
                onOpenSettings: { [weak self] in self?.openSettings(category: $0) },
                onAccountAction: { [weak self] in self?.performAccountAction() }
            )
        }
        let panel = makePanel(content: content)
        positionMainPanel(panel, relativeTo: button)
        attach(panel, to: button.window)
        mainPanel = panel
        startMonitoring()
    }

    private func presentVaultMenu(anchorMinY: CGFloat? = nil) {
        let content = MainSidebarAccountMenuPanel(width: MainSidebarAccountMenuLayout.menuWidth) {
            MainSidebarAccountVaultMenuView(
                navigation: navigation,
                vaults: vaults,
                currentVault: currentVault,
                onSelectVault: { [weak self] vault in self?.selectVault(vault) },
                onManageVaults: { [weak self] in self?.manageVaults() }
            )
        }
        presentSubmenu(content, menu: .vaults, anchorMinY: anchorMinY)
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

    private func presentSubmenu(
        _ content: some View,
        menu: MainSidebarAccountMenuNavigationState.ActiveMenu,
        anchorMinY: CGFloat?
    ) {
        guard let mainPanel else { return }
        dismissAccountHelp()
        resetTypeAhead()
        closePanel(&submenuPanel)
        navigation.showSubmenu(menu)

        let panel = makePanel(content: content)
        positionSubmenu(panel, relativeTo: mainPanel, anchorMinY: anchorMinY)
        attach(panel, to: button?.window)
        submenuPanel = panel
        announce(menu == .vaults ? L10n.vault : L10n.language)
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

    private func scheduleAccountHelp(label: String, rowFrame: CGRect) {
        dismissAccountHelp()
        accountHelpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.presentAccountHelp(label: label, rowFrame: rowFrame)
        }
    }

    private func presentAccountHelp(label: String, rowFrame: CGRect) {
        guard let mainPanel else { return }
        accountHelpTask = nil
        let panel = makePanel(content: DahliaWindowHeaderHelp(label: label, shortcut: nil))
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.setFrameOrigin(MainSidebarAccountMenuLayout.helpOrigin(
            panelSize: panel.frame.size,
            rowFrame: rowFrame,
            mainPanelFrame: mainPanel.frame,
            screenFrame: visibleScreenFrame(containing: mainPanel.frame)
        ))
        attach(panel, to: button?.window)
        accountHelpPanel = panel
    }

    private func dismissAccountHelp() {
        accountHelpTask?.cancel()
        accountHelpTask = nil
        closePanel(&accountHelpPanel)
    }

    private func selectVault(_ vault: VaultRecord) {
        dismissMenu()
        onSelectVault(vault)
    }

    private func manageVaults() {
        dismissMenu()
        onManageVaults()
    }

    private func openSettings(category: SettingsCategory? = nil) {
        dismissMenu()
        onOpenSettings(category)
    }

    private func performAccountAction() {
        dismissMenu()
        onAccountAction()
    }

    private func closeSubmenu() {
        resetTypeAhead()
        closePanel(&submenuPanel)
        navigation.activeMenu = .root
        navigation.submenuSelection = nil
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
        case .root:
            return false
        case .vaults:
            titles = vaults.map(\.name) + [L10n.manageVaults]
            isEnabled = { [vaults, currentVault] index in
                index == vaults.count || vaults[index].id != currentVault?.id
            }
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
                count: 4 + rootMenuOffset,
                isEnabled: { _ in true }
            )
        case .vaults:
            navigation.submenuSelection = MainSidebarAccountMenuNavigationState.nextEnabledIndex(
                from: navigation.submenuSelection,
                direction: direction,
                count: vaults.count + 1,
                isEnabled: { [vaults, currentVault] index in
                    index == vaults.count || vaults[index].id != currentVault?.id
                }
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
        switch selection - rootMenuOffset {
        case 0: presentVaultMenu()
        case 1: presentLanguageMenu()
        default: break
        }
    }

    func activateSelection() {
        switch navigation.activeMenu {
        case .root: activateRootSelection()
        case .vaults: activateVaultSelection()
        case .languages: activateLanguageSelection()
        }
    }

    func activateRootSelection() {
        guard let selection = navigation.rootSelection else { return }
        if account != nil, selection == 0 {
            openSettings(category: .dahliaAccounts)
            return
        }
        switch selection - rootMenuOffset {
        case 0: presentVaultMenu()
        case 1: presentLanguageMenu()
        case 2: openSettings(category: nil)
        case 3: performAccountAction()
        default: break
        }
    }

    func activateVaultSelection() {
        guard let selection = navigation.submenuSelection else { return }
        if selection == vaults.count {
            manageVaults()
        } else if vaults.indices.contains(selection), vaults[selection].id != currentVault?.id {
            selectVault(vaults[selection])
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

    func announceCurrentSelection() {
        let title: String?
        switch navigation.activeMenu {
        case .root:
            let accountServiceName = isCloudAccount == true ? L10n.dahliaCloud : L10n.dahliaServer
            let titles = (account == nil ? [] : [accountServiceName])
                + [L10n.vault, L10n.language, L10n.settings, L10n.manageDahliaAccounts]
            title = navigation.rootSelection.flatMap { titles.indices.contains($0) ? titles[$0] : nil }
        case .vaults:
            guard let selection = navigation.submenuSelection else { return }
            title = if selection == vaults.count {
                L10n.manageVaults
            } else if vaults.indices.contains(selection) {
                vaults[selection].name
            } else {
                nil
            }
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

    var rootMenuOffset: Int { account == nil ? 0 : 1 }
}
