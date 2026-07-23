import SwiftUI

struct SummaryProjectPicker: View {
    let projects: [FlatProjectRow]
    @Binding var selection: UUID?

    var body: some View {
        Picker(L10n.project, selection: $selection) {
            Text(L10n.noProject)
                .tag(nil as UUID?)

            ForEach(projects.filter { !$0.missingOnDisk || $0.id == selection }) { project in
                Text(project.name)
                    .tag(project.id as UUID?)
            }
        }
        .pickerStyle(.menu)
    }
}
