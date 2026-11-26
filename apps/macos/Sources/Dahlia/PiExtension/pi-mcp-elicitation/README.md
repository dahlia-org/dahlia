# pi-mcp-elicitation

[MCP URL mode elicitation](https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation) for
[Pi](https://pi.dev). An MCP server can send you to a web page, for example to sign in to a third-party service or to
approve a call, and Pi continues when you are done.

- Declares `elicitation.url` to every MCP server. Form mode is not supported, so it is not declared.
- `elicitation/create` with `mode: "url"`: shows the server, the page's host and the full URL, and opens the page in
  your browser only if you agree. Nothing opens on its own.
- A request that fails with URLElicitationRequiredError (`-32042`): asks the same for each page, then asks whether you
  finished there and sends the request again. If you do not continue, Pi gets the original error.
- Only `https` pages, and `http` on localhost, are offered. Other URLs are refused without asking.
- While Pi waits for you, progress notifications keep tool calls from timing out.
- Without a UI (print mode, for example) every page is declined.
- Cancelling a request or closing its transport dismisses its prompts and prevents a late answer from opening a page or retrying the call.

## Install

```sh
pi install ./pi-mcp-elicitation
```

The package replaces Pi's built-in MCP extension with the same one (`createMcpExtension`) over transports that handle
elicitation, so `mcp.json`, `/mcp`, OAuth sign-in and tool exposure work as before.

It needs Pi installed from npm (`@earendil-works/pi-coding-agent`), which keeps Pi's MCP runtime
(`dist/extensions/mcp/runtime.js`) as a file. A compiled Pi binary does not; there the package keeps Pi's own MCP and
warns that elicitation is off. Pi has no elicitation support of its own
([earendil-works/pi#10274](https://github.com/earendil-works/pi/issues/10274)).

## Use from a host

`withElicitation(transport, server, prompt, openURL)` from `elicitation.ts` wraps any MCP transport and needs nothing
from Pi; `index.ts` is the Pi extension.

`createMCPElicitationExtension({ confirm })` from `index.ts` builds the extension with a host UI adapter.
`confirm(context, title, message, signal)` returns a boolean and must dismiss its question when the signal aborts.
The default export uses Pi's `ctx.ui.confirm`. A host with a separate UI process can inject its own correlated
open/cancel protocol; Pi's generic RPC confirmation does not notify the host when its signal aborts.

## Test

```sh
npm test
```
