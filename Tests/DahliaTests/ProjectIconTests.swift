@testable import Dahlia
import AppKit
import Testing

struct ProjectIconTests {
    @Test
    func pickerUsesThirtyIcons() {
        #expect(ProjectIcon.allCases.count == 30)
    }

    @Test
    func pickerIconsAreAvailable() {
        for icon in ProjectIcon.allCases {
            #expect(NSImage(systemSymbolName: icon.systemImageName, accessibilityDescription: nil) != nil)
        }
    }
}
