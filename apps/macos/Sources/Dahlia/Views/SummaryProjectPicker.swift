import SwiftUI

struct SummaryProjectPicker: View {
    let projects: [FlatProjectRow]
    @Binding var selection: UUID?

    var body: some View {
        Picker(L10n.project, selection: $selection) {
            Text(L10n.noProject)
                .font(.dahliaBody)
                .tag(nil as UUID?)

            ForEach(projects) { project in
                Text(project.name)
                    .font(.dahliaBody)
                    .tag(project.id as UUID?)
            }
        }
        .pickerStyle(.menu)
    }
}
