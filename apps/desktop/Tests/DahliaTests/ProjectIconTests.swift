import AppKit
import Testing
@testable import Dahlia

struct ProjectIconTests {
    @Test
    func pickerUsesAvailableCollectionIcons() {
        #expect(ProjectIcon.allCases.count == 31)
        for icon in ProjectIcon.allCases {
            #expect(NSImage(systemSymbolName: icon.systemImageName, accessibilityDescription: nil) != nil)
        }
    }
}
