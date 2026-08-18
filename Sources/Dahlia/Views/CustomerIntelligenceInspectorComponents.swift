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
                        .dahliaFont(.displayTitle, weight: .bold)
                        .textSelection(.enabled)
                    if let subtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let badge {
                        Text(badge)
                            .dahliaFont(.body)
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
                .dahliaFont(.subsectionTitle, weight: .semibold)
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
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .dahliaFont(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
                .dahliaFont(.subsectionTitle, weight: .semibold)
            Text(message)
                .dahliaFont(.body)
                .foregroundStyle(.secondary)
            Button(title, systemImage: "trash", role: .destructive, action: action)
        }
        .padding(.top)
    }
}
