@testable import Dahlia
import Testing

struct ProjectIconTests {
    @Test
    func pickerUsesThirtyIcons() {
        #expect(ProjectIcon.allCases.count == 30)
    }
}
