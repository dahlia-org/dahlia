import Observation
import SwiftUI

/// Keeps ancestor popovers open while the pointer is inside a nested submenu.
@MainActor
@Observable
final class BreadcrumbHoverSession {
    private(set) var dismissalGeneration = 0
    private var hoveredPaths: [UUID: [UUID]] = [:]

    func update(id: UUID, ancestors: [UUID], isHovered: Bool) {
        if isHovered {
            hoveredPaths[id] = ancestors + [id]
        } else {
            hoveredPaths.removeValue(forKey: id)
        }
    }

    func dismissAll() {
        hoveredPaths.removeAll()
        dismissalGeneration += 1
    }

    func isHovered(id: UUID) -> Bool {
        hoveredPaths.values.contains { $0.contains(id) }
    }
}

extension EnvironmentValues {
    @Entry var breadcrumbAncestorIDs: [UUID] = []
}
