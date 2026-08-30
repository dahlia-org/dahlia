import SwiftUI

extension View {
    func customerIntelligenceTableStyle() -> some View {
        tableStyle(.inset(alternatesRowBackgrounds: false))
    }

    func customerIntelligenceErrorAlert(
        title: String = L10n.customerIntelligenceUpdateError,
        message: Binding<String?>
    ) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            Button(L10n.close, role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
