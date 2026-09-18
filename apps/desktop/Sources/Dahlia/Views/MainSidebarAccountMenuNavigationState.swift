import Foundation
import Observation

@MainActor
@Observable
final class MainSidebarAccountMenuNavigationState {
    enum ActiveMenu: Equatable {
        case root
        case languages
        case accountDetails
    }

    var activeMenu = ActiveMenu.root
    var rootSelection: Int?
    var submenuSelection: Int?
    private(set) var accountDetailError: String?
    private(set) var accountDetailPresentationID: UUID?

    func reset() {
        activeMenu = .root
        rootSelection = nil
        submenuSelection = nil
        accountDetailError = nil
        accountDetailPresentationID = nil
    }

    func selectRoot(_ index: Int) {
        activeMenu = .root
        rootSelection = index
        submenuSelection = nil
        accountDetailError = nil
        accountDetailPresentationID = nil
    }

    func showSubmenu(_ menu: ActiveMenu) {
        activeMenu = menu
        submenuSelection = nil
        accountDetailError = nil
        accountDetailPresentationID = menu == .accountDetails ? UUID() : nil
    }

    func returnToRoot() {
        activeMenu = .root
        submenuSelection = nil
        accountDetailError = nil
        accountDetailPresentationID = nil
    }

    func selectSubmenu(_ index: Int) {
        submenuSelection = index
    }

    func publishAccountDetailError(_ error: String?, for presentationID: UUID?) {
        guard accountDetailPresentationID == presentationID else { return }
        accountDetailError = error
    }

    static func nextEnabledIndex(
        from currentIndex: Int?,
        direction: Int,
        count: Int,
        isEnabled: (Int) -> Bool
    ) -> Int? {
        guard count > 0 else { return nil }
        var index = currentIndex ?? (direction > 0 ? -1 : 0)
        for _ in 0 ..< count {
            index = (index + direction + count) % count
            if isEnabled(index) {
                return index
            }
        }
        return nil
    }

    static func firstEnabledIndex(
        matching prefix: String,
        titles: [String],
        isEnabled: (Int) -> Bool
    ) -> Int? {
        titles.indices.first { index in
            isEnabled(index) && titles[index].range(
                of: prefix,
                options: [.anchored, .caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) != nil
        }
    }
}
