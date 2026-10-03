import AppKit
import SwiftUI
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatComposerTextEditorTests {
        @Test
        func placeholderIsHiddenWhileEditorIsFocused() {
            #expect(CodexChatComposerTextEditor.shouldShowPlaceholder(text: "", isFocused: false))
            #expect(!CodexChatComposerTextEditor.shouldShowPlaceholder(text: "", isFocused: true))
            #expect(!CodexChatComposerTextEditor.shouldShowPlaceholder(text: "Draft", isFocused: false))
        }

        @Test
        func emptyThroughTwoLinesUseTheMinimumHeight() throws {
            let empty = ComposerTextEditorHarness(text: "")
            let singleLine = ComposerTextEditorHarness(text: "One line")
            let twoLines = ComposerTextEditorHarness(text: lines(2))

            let emptyScrollView = try #require(empty.textView.enclosingScrollView)
            let singleLineScrollView = try #require(singleLine.textView.enclosingScrollView)
            let twoLineScrollView = try #require(twoLines.textView.enclosingScrollView)

            #expect(emptyScrollView.frame.height == singleLineScrollView.frame.height)
            #expect(singleLineScrollView.frame.height == twoLineScrollView.frame.height)
        }

        @Test
        func editorGrowsFromThreeThroughThirteenLinesAndThenCapsItsHeight() throws {
            let twoLines = ComposerTextEditorHarness(text: lines(2))
            let threeLines = ComposerTextEditorHarness(text: lines(3))
            let thirteenLines = ComposerTextEditorHarness(text: lines(13))
            let fourteenLines = ComposerTextEditorHarness(text: lines(14))

            let twoLineScrollView = try #require(twoLines.textView.enclosingScrollView)
            let threeLineScrollView = try #require(threeLines.textView.enclosingScrollView)
            let thirteenLineScrollView = try #require(thirteenLines.textView.enclosingScrollView)
            let fourteenLineScrollView = try #require(fourteenLines.textView.enclosingScrollView)

            #expect(twoLineScrollView.frame.height < threeLineScrollView.frame.height)
            #expect(threeLineScrollView.frame.height < thirteenLineScrollView.frame.height)
            #expect(thirteenLineScrollView.frame.height == fourteenLineScrollView.frame.height)
        }

        @Test
        func editorGrowsForVisuallyWrappedLines() throws {
            let shortDraft = ComposerTextEditorHarness(text: "Short draft")
            let wrappedDraft = ComposerTextEditorHarness(text: String(repeating: "Wrapped content ", count: 20))

            let shortDraftScrollView = try #require(shortDraft.textView.enclosingScrollView)
            let wrappedDraftScrollView = try #require(wrappedDraft.textView.enclosingScrollView)

            #expect(shortDraftScrollView.frame.height < wrappedDraftScrollView.frame.height)
        }

        @Test
        func trailingNewlineCreatesTheNextVisibleLine() throws {
            let twoLines = ComposerTextEditorHarness(text: lines(2))
            let trailingNewline = ComposerTextEditorHarness(text: lines(2) + "\n")

            let twoLineScrollView = try #require(twoLines.textView.enclosingScrollView)
            let trailingNewlineScrollView = try #require(trailingNewline.textView.enclosingScrollView)

            #expect(twoLineScrollView.frame.height < trailingNewlineScrollView.frame.height)
        }

        @Test
        func longDraftScrollsToKeepTheCaretVisible() throws {
            let harness = ComposerTextEditorHarness(text: String(repeating: "Line\n", count: 20))
            let scrollView = try #require(harness.textView.enclosingScrollView)
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)

            harness.textView.setSelectedRange(NSRange(location: harness.textView.string.utf16.count, length: 0))
            harness.textView.scrollRangeToVisible(harness.textView.selectedRange())

            #expect(scrollView.documentVisibleRect.origin.y > 0)
        }

        @Test
        func tabDoesNotChangeTheDraft() throws {
            let harness = ComposerTextEditorHarness(text: "Draft")
            try harness.sendKeyDown(characters: "\t", keyCode: 48)

            #expect(harness.state.text == "Draft")
        }

        @Test
        func returnSubmitsWithoutChangingTheDraft() throws {
            let harness = ComposerTextEditorHarness(text: "Draft")
            try harness.sendKeyDown(characters: "\r", keyCode: 36)

            #expect(harness.state.submissionCount == 1)
            #expect(harness.state.text == "Draft")
        }

        @Test
        func shiftReturnInsertsNewlineWithoutSubmitting() throws {
            let harness = ComposerTextEditorHarness(text: "Draft")
            harness.textView.setSelectedRange(NSRange(location: harness.textView.string.utf16.count, length: 0))
            try harness.sendKeyDown(characters: "\r", modifierFlags: .shift, keyCode: 36)

            #expect(harness.state.submissionCount == 0)
            #expect(harness.state.text == "Draft\n")
        }

        private func lines(_ count: Int) -> String {
            (1 ... count).map(String.init).joined(separator: "\n")
        }
    }

    @MainActor
    private final class ComposerTextEditorHarness {
        let state: ComposerTextEditorState
        let window: NSWindow
        let hostingView: NSHostingView<ComposerTextEditorFixture>
        let textView: NSTextView

        init(text: String) {
            let state = ComposerTextEditorState(text: text)
            self.state = state
            let fixture = ComposerTextEditorFixture(
                text: Binding(
                    get: { state.text },
                    set: { state.text = $0 }
                ),
                onSubmit: { state.submissionCount += 1 }
            )
            hostingView = NSHostingView(rootView: fixture)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            hostingView.layoutSubtreeIfNeeded()
            guard let textView = hostingView.firstDescendant(ofType: NSTextView.self) else {
                preconditionFailure("Composer TextEditor must provide an NSTextView")
            }
            self.textView = textView
        }

        func sendKeyDown(
            characters: String,
            modifierFlags: NSEvent.ModifierFlags = [],
            keyCode: UInt16
        ) throws {
            #expect(window.makeFirstResponder(textView))
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ))
            window.sendEvent(event)
        }
    }

    @MainActor
    private final class ComposerTextEditorState {
        var text: String
        var submissionCount = 0

        init(text: String) {
            self.text = text
        }
    }

    private struct ComposerTextEditorFixture: View {
        @Binding var text: String
        let onSubmit: () -> Void

        @FocusState private var isFocused: Bool

        var body: some View {
            CodexChatComposerTextEditor(
                text: $text,
                isFocused: $isFocused,
                onSubmit: onSubmit,
                onMoveCommand: { _ in },
                onExitCommand: {},
                onPasteImages: { false },
                onHover: { _ in }
            )
            .frame(width: 300)
            .padding()
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
