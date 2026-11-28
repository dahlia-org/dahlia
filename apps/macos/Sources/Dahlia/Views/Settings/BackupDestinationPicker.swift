import SwiftUI

/// The backup destination as a dropdown whose rows show the provider's logo, its name, and where backups go.
/// A native menu cannot show a logo and a second line, so this opens a popover list instead.
struct BackupDestinationPicker: View {
    let options: [BackupStorageOption]
    let selection: ProviderAccount?
    let onSelect: (ProviderAccount?) -> Void
    @State private var isPresented = false
    @State private var isHovered = false
    @State private var locations: [UUID: String] = [:]

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 10) {
                row(selection.flatMap { account in options.first { $0.account == account } })
                Image(systemName: "chevron.up.chevron.down")
                    .font(.dahliaSecondary)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(isHovered ? Color.secondary.opacity(0.1) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(L10n.backupStorageDestination)
        .accessibilityValue(selection.flatMap { account in options.first { $0.account == account }?.name } ?? L10n.backupStorageThisMacOnly)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                choice(nil)
                ForEach(options) { choice($0) }
            }
            .padding(6)
            .frame(minWidth: 360)
        }
        .task(id: options) { await loadLocations() }
        .onChange(of: isPresented) { _, presented in
            if presented { Task { await loadLocations() } }
        }
    }

    private func choice(_ option: BackupStorageOption?) -> some View {
        BackupDestinationChoice(isSelected: option?.account == selection) {
            onSelect(option?.account)
            isPresented = false
        } label: {
            row(option)
        }
    }

    /// Nil is "This Mac only".
    private func row(_ option: BackupStorageOption?) -> some View {
        HStack(spacing: 10) {
            icon(option).resizable().scaledToFit().frame(width: 18, height: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(option?.name ?? L10n.backupStorageThisMacOnly).font(.dahliaBody).lineLimit(1)
                Text(subtitle(option))
                    .font(.dahliaSecondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private func icon(_ option: BackupStorageOption?) -> Image {
        switch option?.account {
        case .google: .googleLogo
        case .databricks: .databricksLogo
        case .dahlia, nil: Image(systemName: "laptopcomputer")
        }
    }

    private func subtitle(_ option: BackupStorageOption?) -> String {
        guard let option else { return L10n.backupLocalCopies }
        return locations[option.id] ?? "…"
    }

    private func loadLocations() async {
        for option in options {
            let text: String
            do {
                text = try await option.account.backupLocationDescription() ?? L10n.backupStorageSchemaNotConfigured
            } catch {
                text = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            locations[option.id] = text
        }
    }
}

/// One row of the destination list, highlighted on hover like a menu item.
private struct BackupDestinationChoice<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                label
                Image(systemName: "checkmark")
                    .font(.dahliaSecondary.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isHovered ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
