import SwiftUI

struct DahliaSheetActionBar<Actions: View>: View {
    let alignsActionsTrailing: Bool
    @ViewBuilder let actions: Actions

    init(
        alignsActionsTrailing: Bool = true,
        @ViewBuilder actions: () -> Actions
    ) {
        self.alignsActionsTrailing = alignsActionsTrailing
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 8) {
            if alignsActionsTrailing {
                Spacer(minLength: 12)
            }
            actions
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
