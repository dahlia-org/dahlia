import { createMCPElicitationExtension } from "./pi-mcp-elicitation/index.ts";
import { confirmInHost } from "./mcp-elicitation-confirm.ts";

export default createMCPElicitationExtension({ confirm: confirmInHost });
