#if canImport(Testing)
    import AppKit
    import Observation
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct DocumentEditorErrorPreferenceTests {
        @Test
        func emptySiblingIsNeutralDuringReduction() {
            var error = "save failed"
            DocumentEditorErrorPreferenceKey.reduce(value: &error) { DocumentEditorErrorPreferenceKey.defaultValue }
            #expect(error == "save failed")

            var fresh = DocumentEditorErrorPreferenceKey.defaultValue
            DocumentEditorErrorPreferenceKey.reduce(value: &fresh) { "save failed" }
            #expect(fresh == "save failed")

            var cleared = DocumentEditorErrorPreferenceKey.defaultValue
            DocumentEditorErrorPreferenceKey.reduce(value: &cleared) { "" }
            #expect(cleared.isEmpty)
        }

        @Test
        func progressSiblingPreservesErrorAndFreshTreeClearsIt() async {
            let state = NotesErrorPreferenceFixtureState()
            let host = NSHostingView(rootView: NotesErrorPreferenceFixture(state: state))
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
            #expect(await pollUntil {
                host.layoutSubtreeIfNeeded()
                return state.observed == "save failed"
            })

            state.error = ""
            #expect(await pollUntil {
                host.layoutSubtreeIfNeeded()
                return state.observed?.isEmpty == true
            })

            state.error = "another failure"
            #expect(await pollUntil {
                host.layoutSubtreeIfNeeded()
                return state.observed == "another failure"
            })
            state.showsEditor = false
            #expect(await pollUntil {
                host.layoutSubtreeIfNeeded()
                return state.observed?.isEmpty == true
            })
        }
    }

    private struct NotesErrorPreferenceFixture: View {
        @Bindable var state: NotesErrorPreferenceFixtureState

        var body: some View {
            ScrollView {
                VStack {
                    if state.showsEditor {
                        Color.clear
                            .frame(height: 2000)
                            .preference(key: DocumentEditorErrorPreferenceKey.self, value: state.error)
                    }
                    ProgressView()
                }
            }
            .onPreferenceChange(DocumentEditorErrorPreferenceKey.self) { state.observed = $0 }
        }
    }

    @MainActor @Observable
    private final class NotesErrorPreferenceFixtureState {
        var error = "save failed"
        var showsEditor = true
        var observed: String?
    }
#endif
