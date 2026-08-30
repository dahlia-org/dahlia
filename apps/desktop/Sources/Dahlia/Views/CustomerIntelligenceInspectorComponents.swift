import SwiftUI

struct CustomerIntelligenceInspectorHeader: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let badge: String?
    let onEdit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: systemImage)
                    .dahliaFixedSymbol()
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3)
                        .textSelection(.enabled)
                    if let subtitle {
                        Text(subtitle)
                            .foregroundStyle(DahliaDesign.secondaryTextColor)
                            .textSelection(.enabled)
                    }
                    if let badge {
                        Text(badge)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if let onEdit {
                    Button(L10n.edit, systemImage: "pencil", action: onEdit)
                }
            }
            Divider()
        }
    }
}

struct CustomerIntelligenceInspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content
        }
    }
}

struct CustomerIntelligenceLinkRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(DahliaDesign.secondaryTextColor)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.caption)
                    .foregroundStyle(DahliaDesign.optionalTextColor)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct CustomerIntelligenceDangerSection: View {
    let title: String
    let message: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(L10n.customerIntelligenceDangerZone)
                .font(.headline)
            Text(message)
                .font(.body)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
            Button(title, systemImage: "trash", role: .destructive, action: action)
        }
        .padding(.top)
    }
}
