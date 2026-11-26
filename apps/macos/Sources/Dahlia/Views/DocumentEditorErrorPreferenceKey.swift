import SwiftUI

struct DocumentEditorErrorPreferenceKey: PreferenceKey {
    static let defaultValue = ""

    static func reduce(value: inout String, nextValue: () -> String) {
        value = nextValue()
    }
}
