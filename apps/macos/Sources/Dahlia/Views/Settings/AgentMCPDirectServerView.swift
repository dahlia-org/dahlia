import SwiftUI

/// Adds or edits an MCP server configured directly: a stdio command or a streamable HTTP URL.
struct AgentMCPDirectServerView: View {
    let model: AgentMCPSettingsModel
    let server: AgentMCPServer?
    let onClose: () -> Void
    @State private var name: String
    @State private var transport: AgentMCPDirectConfiguration.Transport
    @State private var command: String
    @State private var args: [ArgumentRow]
    @State private var env: [KeyValueRow]
    @State private var url: String
    @State private var headers: [KeyValueRow]
    @State private var isJSON = false
    @State private var jsonText = ""
    @State private var errorMessage: String?

    init(model: AgentMCPSettingsModel, server: AgentMCPServer?, onClose: @escaping () -> Void) {
        self.model = model
        self.server = server
        self.onClose = onClose
        let configuration = server?.direct ?? AgentMCPDirectConfiguration()
        _name = State(initialValue: server?.name ?? "")
        _transport = State(initialValue: configuration.transport)
        _command = State(initialValue: configuration.command)
        _args = State(initialValue: configuration.args.map { ArgumentRow(value: $0) })
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
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.mcpDirectName).foregroundStyle(.secondary)
                if server == nil {
                    TextField(L10n.mcpDirectName, text: $name, prompt: Text("slack"))
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text(name).textSelection(.enabled)
                }
            }
            Picker(L10n.mcpDirectInputMode, selection: Binding(get: { isJSON }, set: switchMode)) {
                Text(L10n.mcpDirectForm).font(.dahliaBody).tag(false)
                Text("JSON").font(.dahliaBody).tag(true)
            }
            .pickerStyle(.segmented)
            if isJSON {
                editor("JSON", text: $jsonText)
                Text(L10n.mcpDirectJSONHelp).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.mcpDirectTransport).foregroundStyle(.secondary)
                    Picker(L10n.mcpDirectTransport, selection: $transport) {
                        Text("stdio").font(.dahliaBody).tag(AgentMCPDirectConfiguration.Transport.stdio)
                        Text("HTTP").font(.dahliaBody).tag(AgentMCPDirectConfiguration.Transport.http)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                switch transport {
                case .stdio:
                    field(L10n.mcpDirectCommand, text: $command, placeholder: "/bin/bash")
                    arguments
                    pairs(L10n.mcpDirectEnvironment, rows: $env, keyPrompt: "API_KEY")
                case .http:
                    field(L10n.mcpDirectURL, text: $url, placeholder: "https://example.com/mcp")
                    pairs(L10n.mcpDirectHeaders, rows: $headers, keyPrompt: "Authorization")
                }
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
                .frame(height: 240)
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

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            TextField(title, text: text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
        }
    }

    private var arguments: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.mcpDirectArguments).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.add, systemImage: "plus") { args.append(ArgumentRow()) }
                    .labelStyle(.iconOnly)
                    .help(L10n.add)
                    .buttonStyle(AgentMCPIconButtonStyle())
            }
            ForEach($args) { $argument in
                HStack(spacing: 8) {
                    TextField(L10n.mcpDirectArgument, text: $argument.value, axis: .vertical)
                        .lineLimit(1 ... 4)
                        .textFieldStyle(.roundedBorder)
                        .font(.dahliaBody.monospaced())
                    Button(L10n.delete, systemImage: "minus") { args.removeAll { $0.id == argument.id } }
                        .labelStyle(.iconOnly)
                        .help(L10n.delete)
                        .buttonStyle(AgentMCPIconButtonStyle())
                }
            }
        }
    }

    private func formConfiguration() throws -> AgentMCPDirectConfiguration {
        try .parse(
            transport: transport,
            command: command,
            arguments: args.map(\.value),
            environment: env.map(\.pair),
            url: url,
            headers: headers.map(\.pair)
        )
    }

    private func jsonConfiguration() throws -> AgentMCPDirectConfiguration {
        let parsed = try AgentMCPDirectConfiguration.parseJSON(jsonText)
        if let importedName = parsed.name {
            if let server, server.name != importedName { throw AgentMCPSettingsError(message: L10n.mcpDirectJSONNameMismatch) }
            name = importedName
        }
        return parsed.configuration
    }

    private func switchMode(_ useJSON: Bool) {
        do {
            if useJSON {
                jsonText = try formConfiguration().jsonString()
            } else {
                let configuration = try jsonConfiguration()
                transport = configuration.transport
                command = configuration.command
                args = configuration.args.map { ArgumentRow(value: $0) }
                env = KeyValueRow.rows(configuration.env)
                url = configuration.url
                headers = KeyValueRow.rows(configuration.headers)
            }
            isJSON = useJSON
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            var configuration = try isJSON ? jsonConfiguration() : formConfiguration()
            configuration.isEnabled = server?.direct?.isEnabled ?? true
            try model.saveDirectServer(name: name, configuration, replacing: server)
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ArgumentRow: Identifiable {
    let id = UUID()
    var value = ""
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
