import AppKit
import Testing
@testable import Dahlia

struct ProjectIconTests {
    @Test
    func workspaceUsesTheApplicationGridIcon() {
        #expect(ProjectIcon.workspace.systemImageName == "square.grid.2x2")
    }

    @Test
    func pickerUsesAvailableCollectionIcons() {
        for icon in ProjectIcon.allCases {
            #expect(NSImage(systemSymbolName: icon.systemImageName, accessibilityDescription: nil) != nil)
        }
    }
}
