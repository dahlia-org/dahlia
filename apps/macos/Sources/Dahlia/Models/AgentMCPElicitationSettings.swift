import Foundation

/// pi-mcp-elicitation lets MCP servers send the user to a web page, to sign in or approve a call. Dahlia bundles it and
/// chat always loads it in place of Pi's own MCP extension; Pi without its MCP runtime (a compiled binary) keeps Pi's MCP.
enum AgentMCPElicitationSettings {
    static let packageName = "pi-mcp-elicitation"

    /// The extension chat loads; Pi reports it as the source of MCP tools.
    static func entryURL() throws -> URL {
        try PiBundle.resourceURL("dahlia-mcp.ts")
    }
}
