#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

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
            let model = ProjectDescriptionTextViewFixtureModel()
            let hostingView = NSHostingView(rootView: ProjectDescriptionTextViewFixture(model: model).disabled(false))
            hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 160)
            hostingView.layoutSubtreeIfNeeded()

            let textView = try #require(hostingView.firstDescendant(ofType: ProjectDescriptionNSTextView.self))
            #expect(textView.isEditable)
            #expect(textView.font?.pointSize == NSFont.preferredFont(forTextStyle: .body).pointSize)

            hostingView.rootView = ProjectDescriptionTextViewFixture(model: model).disabled(true)
            hostingView.layoutSubtreeIfNeeded()

            #expect(!textView.isEditable)
        }

        @Test
        func externalUpdatePreservesSelection() throws {
            let model = ProjectDescriptionTextViewFixtureModel(text: "abcdef")
            let hostingView = NSHostingView(rootView: ProjectDescriptionTextViewFixture(model: model))
            hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 160)
            hostingView.layoutSubtreeIfNeeded()

            let textView = try #require(hostingView.firstDescendant(ofType: ProjectDescriptionNSTextView.self))
            textView.setSelectedRange(NSRange(location: 2, length: 3))

            model.text = "abcdefgh"
            hostingView.layoutSubtreeIfNeeded()

            #expect(textView.string == "abcdefgh")
            #expect(textView.selectedRange() == NSRange(location: 2, length: 3))
        }
    }

    @MainActor
    private final class ProjectDescriptionTextViewFixtureModel: ObservableObject {
        @Published var text: String

        init(text: String = "") {
            self.text = text
        }
    }

    private struct ProjectDescriptionTextViewFixture: View {
        @ObservedObject var model: ProjectDescriptionTextViewFixtureModel
        @FocusState private var isFocused: Bool

        var body: some View {
            ProjectDescriptionTextView(text: $model.text, isFocused: $isFocused)
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
