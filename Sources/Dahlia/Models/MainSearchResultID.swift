import Foundation

enum MainSearchResultID: Hashable {
    case meeting(UUID)
    case screenshot(UUID)
    case project(UUID)
}
