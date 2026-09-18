import AppKit
import SwiftUI

struct NonAutofocusingSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> PickerSearchField {
        let searchField = PickerSearchField()
        searchField.delegate = context.coordinator
        searchField.placeholderString = placeholder
        return searchField
    }

    func updateNSView(_ nsView: PickerSearchField, context: Context) {
        context.coordinator.parent = self
        nsView.placeholderString = placeholder

        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        guard let window = nsView.window else { return }

        if isFocused {
            let currentEditor = nsView.currentEditor()
            guard window.firstResponder !== nsView, window.firstResponder !== currentEditor else { return }
            nsView.beginUserInitiatedFocus()
            window.makeFirstResponder(nsView)
            nsView.endUserInitiatedFocus()
        } else {
            let currentEditor = nsView.currentEditor()
            guard window.firstResponder === nsView || window.firstResponder === currentEditor else { return }
            window.makeFirstResponder(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NonAutofocusingSearchField

        init(parent: NonAutofocusingSearchField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_: Notification) {
            parent.isFocused = true
        }

        func controlTextDidEndEditing(_: Notification) {
            parent.isFocused = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            commandSelector == #selector(NSResponder.insertNewline(_:))
        }
    }
}

final class PickerSearchField: NSSearchField {
    private var hasSuppressedAutomaticFocus = false
    private var userInitiatedFocus = false

    override func becomeFirstResponder() -> Bool {
        if shouldSuppressAutomaticFocusAttempt {
            hasSuppressedAutomaticFocus = true
            return false
        }
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        beginUserInitiatedFocus()
        super.mouseDown(with: event)
        endUserInitiatedFocus()
    }

    func beginUserInitiatedFocus() {
        userInitiatedFocus = true
    }

    func endUserInitiatedFocus() {
        userInitiatedFocus = false
    }

    private var shouldSuppressAutomaticFocusAttempt: Bool {
        guard !hasSuppressedAutomaticFocus, !userInitiatedFocus else { return false }
        return NSApp.currentEvent?.type != .keyDown
    }
}
