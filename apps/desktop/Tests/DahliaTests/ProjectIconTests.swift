import AppKit
import Testing
@testable import Dahlia

struct ProjectIconTests {
    @Test
    func pickerUsesThirtyAvailableIcons() {
        #expect(ProjectIcon.allCases.count == 30)
        for icon in ProjectIcon.allCases {
            #expect(NSImage(systemSymbolName: icon.systemImageName, accessibilityDescription: nil) != nil)
        }
    }
}
