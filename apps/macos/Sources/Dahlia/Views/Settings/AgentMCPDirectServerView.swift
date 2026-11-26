import SwiftUI

/// Adds or edits an MCP server configured directly: a stdio command or a streamable HTTP URL.
struct AgentMCPDirectServerView: View {
    let model: AgentMCPSettingsModel
    let server: AgentMCPServer?
    let onClose: () -> Void
    @State private var name: String
    @State private var transport: AgentMCPDirectConfiguration.Transport
    @State private var command: String
    @State private var args: String
    @State private var env: [KeyValueRow]
    @State private var url: String
    @State private var headers: [KeyValueRow]
    @State private var errorMessage: String?

    init(model: AgentMCPSettingsModel, server: AgentMCPServer?, onClose: @escaping () -> Void) {
        self.model = model
        self.server = server
        self.onClose = onClose
        let configuration = server?.direct ?? AgentMCPDirectConfiguration()
        _name = State(initialValue: server?.name ?? "")
        _transport = State(initialValue: configuration.transport)
        _command = State(initialValue: configuration.command)
        _args = State(initialValue: configuration.args.joined(separator: "\n"))
        _env = State(initialValue: KeyValueRow.rows(configuration.env))
        _url = State(initialValue: configuration.url)
        _headers = State(initialValue: KeyValueRow.rows(configuration.headers))
    }

    var body: some View {
        ZStack {
            Button(action: onClose) {
                Color.black.opacity(0.16).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)

            ViewThatFits(in: .vertical) {
                form
                ScrollView { form }
                    .scrollBounceBehavior(.basedOnSize)
            }
            .padding(24)
            .frame(width: 520)
            .dahliaModalSurface()
            .padding(.vertical, 24)
        }
        .transition(.identity)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(server?.name ?? L10n.mcpAddService)
                .font(.dahliaTitle2)
                .accessibilityAddTraits(.isHeader)
            if server == nil {
                TextField(L10n.mcpDirectName, text: $name, prompt: Text("slack"))
                    .textFieldStyle(.roundedBorder)
            }
            Picker(L10n.mcpDirectTransport, selection: $transport) {
                Text("stdio").font(.dahliaBody).tag(AgentMCPDirectConfiguration.Transport.stdio)
                Text("HTTP").font(.dahliaBody).tag(AgentMCPDirectConfiguration.Transport.http)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch transport {
            case .stdio:
                TextField(L10n.mcpDirectCommand, text: $command, prompt: Text("/bin/bash"))
                    .textFieldStyle(.roundedBorder)
                editor(L10n.mcpDirectArguments, text: $args)
                pairs(L10n.mcpDirectEnvironment, rows: $env, keyPrompt: "API_KEY")
            case .http:
                TextField("URL", text: $url, prompt: Text("https://example.com/mcp"))
                    .textFieldStyle(.roundedBorder)
                pairs(L10n.mcpDirectHeaders, rows: $headers, keyPrompt: "Authorization")
            }
            Text(L10n.mcpDirectHelp).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                if let server {
                    Button(L10n.delete, role: .destructive) {
                        model.remove(server)
                        onClose()
                    }
                    .buttonStyle(.dahlia())
                }
                Spacer()
                Button(L10n.cancel, action: onClose)
                    .buttonStyle(.dahlia())
                    .keyboardShortcut(.cancelAction)
                Button(server == nil ? L10n.add : L10n.save, action: save)
                    .buttonStyle(.dahlia(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func editor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.dahliaBody.monospaced())
                .scrollContentBackground(.hidden)
                .frame(height: 72)
                .padding(6)
                .background(.background, in: .rect(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel(title)
        }
    }

    /// Name and value fields per row; + adds a row and - removes one.
    private func pairs(_ title: String, rows: Binding<[KeyValueRow]>, keyPrompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.add, systemImage: "plus") { rows.wrappedValue.append(KeyValueRow()) }
                    .labelStyle(.iconOnly)
                    .help(L10n.add)
                    .buttonStyle(AgentMCPIconButtonStyle())
            }
            ForEach(rows) { $row in
                HStack(spacing: 8) {
                    TextField(L10n.mcpDirectPairKey, text: $row.key, prompt: Text(keyPrompt))
                        .accessibilityLabel("\(title) \(L10n.mcpDirectPairKey)")
                    TextField(L10n.mcpDirectPairValue, text: $row.value, prompt: Text("${VAR}"))
                        .accessibilityLabel("\(title) \(L10n.mcpDirectPairValue)")
                    Button(L10n.delete, systemImage: "minus") { rows.wrappedValue.removeAll { $0.id == row.id } }
                        .labelStyle(.iconOnly)
                        .help(L10n.delete)
                        .buttonStyle(AgentMCPIconButtonStyle())
                }
                .textFieldStyle(.roundedBorder)
                .font(.dahliaBody.monospaced())
            }
        }
    }

    private func save() {
        do {
            var configuration = try AgentMCPDirectConfiguration.parse(
                transport: transport, command: command, arguments: args, environment: env.map(\.pair), url: url, headers: headers.map(\.pair)
            )
            configuration.isEnabled = server?.direct?.isEnabled ?? true
            try model.saveDirectServer(name: name, configuration, replacing: server)
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct KeyValueRow: Identifiable {
    let id = UUID()
    var key = ""
    var value = ""

    var pair: AgentMCPDirectConfiguration.Pair {
        (key, value)
    }

    static func rows(_ pairs: [String: String]) -> [Self] {
        pairs.sorted { $0.key < $1.key }.map { Self(key: $0.key, value: $0.value) }
    }
}
