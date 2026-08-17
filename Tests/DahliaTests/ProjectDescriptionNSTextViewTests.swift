#if canImport(Testing)
@testable import Dahlia
import AppKit
import SwiftUI
import Testing

@MainActor
struct ProjectDescriptionNSTextViewTests {
    @Test
    func returnAndShiftReturnInsertNewlines() throws {
        for modifiers: NSEvent.ModifierFlags in [[], [.shift]] {
            let textView = ProjectDescriptionNSTextView()
            textView.string = "ab"
            textView.setSelectedRange(NSRange(location: 1, length: 0))

            let event = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            ))
            textView.keyDown(with: event)

            #expect(textView.string == "a\nb")
        }
    }

    @Test
    func editorBecomesNonEditableWhenDisabled() throws {
        let hostingView = NSHostingView(rootView: ProjectDescriptionTextViewFixture().disabled(false))
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 160)
        hostingView.layoutSubtreeIfNeeded()

        let textView = try #require(hostingView.firstDescendant(ofType: ProjectDescriptionNSTextView.self))
        #expect(textView.isEditable)

        hostingView.rootView = ProjectDescriptionTextViewFixture().disabled(true)
        hostingView.layoutSubtreeIfNeeded()

        #expect(!textView.isEditable)
    }
}

private struct ProjectDescriptionTextViewFixture: View {
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        ProjectDescriptionTextView(text: $text, isFocused: $isFocused)
    }
}

private extension NSView {
    func firstDescendant<ViewType: NSView>(ofType _: ViewType.Type) -> ViewType? {
        if let view = self as? ViewType {
            return view
        }
        for subview in subviews {
            if let view = subview.firstDescendant(ofType: ViewType.self) {
                return view
            }
        }
        return nil
    }
}
#endif
