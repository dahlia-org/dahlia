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
    @State private var env: String
    @State private var url: String
    @State private var headers: String
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
        _env = State(initialValue: AgentMCPDirectConfiguration.lines(configuration.env, separator: "="))
        _url = State(initialValue: configuration.url)
        _headers = State(initialValue: AgentMCPDirectConfiguration.lines(configuration.headers, separator: ": "))
    }

    var body: some View {
        ZStack {
            Button(action: onClose) {
                Color.black.opacity(0.16).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)

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
                    editor(L10n.mcpDirectEnvironment, text: $env)
                case .http:
                    TextField("URL", text: $url, prompt: Text("https://example.com/mcp"))
                        .textFieldStyle(.roundedBorder)
                    editor(L10n.mcpDirectHeaders, text: $headers)
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
            .padding(24)
            .frame(width: 520)
            .dahliaModalSurface()
        }
        .transition(.identity)
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

    private func save() {
        guard let env = AgentMCPDirectConfiguration.pairs(env, separator: "="),
              let headers = AgentMCPDirectConfiguration.pairs(headers, separator: ":") else {
            errorMessage = L10n.mcpDirectPairsInvalid
            return
        }
        let configuration = AgentMCPDirectConfiguration(
            transport: transport, isEnabled: server?.direct?.isEnabled ?? true,
            command: command.trimmingCharacters(in: .whitespaces),
            // One argument per line, kept as written: an argument such as `bash -c`'s script may have spaces and quotes.
            args: args.split(whereSeparator: \.isNewline).map(String.init),
            env: env, url: url.trimmingCharacters(in: .whitespaces), headers: headers
        )
        do {
            try model.saveDirectServer(name: name, configuration, replacing: server)
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
