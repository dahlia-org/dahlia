import Foundation
import Observation

@MainActor
@Observable
final class MainSidebarAccountMenuNavigationState {
    enum ActiveMenu {
        case root
        case vaults
        case languages
    }

    var activeMenu = ActiveMenu.root
    var rootSelection: Int?
    var submenuSelection: Int?

    func reset() {
        activeMenu = .root
        rootSelection = nil
        submenuSelection = nil
    }

    func selectRoot(_ index: Int) {
        activeMenu = .root
        rootSelection = index
        submenuSelection = nil
    }

    func showSubmenu(_ menu: ActiveMenu) {
        activeMenu = menu
        submenuSelection = nil
    }

    func selectSubmenu(_ index: Int) {
        submenuSelection = index
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
