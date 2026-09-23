import { useEffect, useState } from "react";

import { json, uiText } from "./api";
import { Button } from "./components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "./components/ui/dialog";
import { Input } from "./components/ui/input";
import { Tabs, TabsList, TabsTrigger } from "./components/ui/tabs";

export type MCPClient = "mcpJSON" | "claude" | "codex";

type MCPSettings = { url: string; available: boolean } & (
  { databricksProxy: false; proxyUrl?: never }
  | { databricksProxy: true; proxyUrl: string }
);

interface MCPConnectionInfo { mcp: MCPSettings }

export function parseMCPConnectionInfo(value: unknown): MCPConnectionInfo {
  const mcp = typeof value === "object" && value !== null && "mcp" in value ? value.mcp : undefined;
  if (typeof mcp === "object" && mcp !== null && "url" in mcp && typeof mcp.url === "string"
    && "databricksProxy" in mcp && typeof mcp.databricksProxy === "boolean"
    && "available" in mcp && typeof mcp.available === "boolean") {
    const proxyUrl = "proxyUrl" in mcp ? mcp.proxyUrl : undefined;
    try {
      const protocol = new URL(mcp.url).protocol;
      if (!["http:", "https:"].includes(protocol)) throw new Error();
      if (!mcp.databricksProxy) return { mcp: { url: mcp.url, databricksProxy: false, available: mcp.available } };
      if (typeof proxyUrl === "string" && ["http:", "https:"].includes(new URL(proxyUrl).protocol)) {
        return { mcp: { url: mcp.url, proxyUrl, databricksProxy: true, available: mcp.available } };
      }
    } catch { /* Report the same invalid-response error below. */ }
  }
  throw new Error(uiText("The Server returned invalid MCP settings", "Server から無効な MCP 設定が返されました"));
}

function shellArgument(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

export function mcpConnectionOutput(client: MCPClient, mcp: MCPConnectionInfo["mcp"], profile = "DEFAULT", memory = false): string {
  const url = mcp.databricksProxy ? mcp.proxyUrl : mcp.url;
  const normalizedProfile = profile.trim() || "DEFAULT";
  if (client === "mcpJSON") {
    return JSON.stringify({
      mcpServers: {
        dahlia: mcp.databricksProxy
          ? { type: "stdio", command: "uvx", args: ["uc-mcp-proxy", "--url", url, "--profile", normalizedProfile] }
          : { type: "http", url },
      },
    }, null, 2);
  }
  if (mcp.databricksProxy) {
    const command = `uvx uc-mcp-proxy --url ${shellArgument(url)} --profile ${shellArgument(normalizedProfile)}`;
    return client === "claude"
      ? `claude mcp add --scope user dahlia -- ${command}`
      : `codex mcp add dahlia -- ${command}`;
  }
  return client === "claude"
    ? `claude mcp add --scope user --transport http dahlia ${shellArgument(url)}`
    : `codex mcp add dahlia --url ${shellArgument(url)}${memory ? "\ncodex mcp login dahlia --scopes mcp:read,mcp:memory:write" : ""}`;
}

const clients: Array<{ id: MCPClient; label: string }> = [
  { id: "mcpJSON", label: "mcp.json" },
  { id: "claude", label: "Claude Code" },
  { id: "codex", label: "Codex" },
];

export function MCPConnectionDialog({ onClose, memory = false }: { onClose: () => void; memory?: boolean }) {
  const [connection, setConnection] = useState<MCPConnectionInfo>();
  const [error, setError] = useState<string>();
  const [client, setClient] = useState<MCPClient>("mcpJSON");
  const [profile, setProfile] = useState("DEFAULT");
  const [copyState, setCopyState] = useState<"idle" | "copied" | "failed">("idle");

  useEffect(() => {
    const controller = new AbortController();
    void json<unknown>("/api/auth/mode", { signal: controller.signal })
      .then((value) => setConnection(parseMCPConnectionInfo(value)))
      .catch((caught: unknown) => {
        if (!controller.signal.aborted) setError(caught instanceof Error ? caught.message : uiText("Could not load MCP settings", "MCP 設定を読み込めませんでした"));
      });
    return () => controller.abort();
  }, []);

  const mcpUnavailable = connection?.mcp.available === false;
  const canConfigure = !error && !mcpUnavailable;
  const output = connection ? mcpConnectionOutput(client, connection.mcp, profile, memory) : "";
  async function copy() {
    try {
      await navigator.clipboard.writeText(output);
      setCopyState("copied");
      window.setTimeout(() => setCopyState("idle"), 2000);
    } catch {
      setCopyState("failed");
    }
  }

  return <Dialog open onOpenChange={(value) => { if (!value) onClose(); }}>
    <DialogContent className="max-w-2xl">
    <DialogHeader>
      <DialogTitle>{uiText("Connect with MCP", "MCP による接続")}</DialogTitle>
      <DialogDescription>{uiText(
        "Connect an MCP client to search and read meetings in the Workspaces you can access.",
        "アクセスできるワークスペースのミーティングを検索・参照できるよう、MCP クライアントを接続します。",
      )}</DialogDescription>
    </DialogHeader>
    <div className="grid gap-4">
      {memory && <p className="text-sm" role="note">{uiText(
        "Dahlia Memory requires a separate memory permission. Approve memory read/write in the OAuth flow; reconnect existing clients. Databricks Apps requires the operator to enable Memory MCP access. Shared saves still require your explicit instruction.",
        "Dahlia Memory は独立したメモリー権限を使います。OAuth でメモリーの読み書きを許可し、既存の接続は再認証してください。Databricks Apps は管理者による Memory MCP の有効化が必要です。共有への保存には引き続き明示的な依頼が必要です。",
      )}</p>}
      {connection?.mcp.databricksProxy && <div className="grid gap-1 rounded-lg border bg-muted/50 p-3 text-sm">
        <strong>{uiText("Databricks Apps authentication", "Databricks Apps の認証")}</strong>
        <span className="leading-6 text-muted-foreground">{uiText(
          "This deployment connects through uvx uc-mcp-proxy. Install uv and configure a Databricks CLI profile first; an expired OAuth profile opens browser login automatically.",
          "この環境では uvx uc-mcp-proxy を経由します。事前に uv を用意し、Databricks CLI プロファイルを設定してください。OAuth の期限切れ時はブラウザ認証が自動で開きます。",
        )}</span>
      </div>}
      {mcpUnavailable && <div className="grid gap-1 rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm" role="status">
        <strong>{uiText("MCP setup is unavailable in this deployment", "この環境では MCP 接続を設定できません")}</strong>
        <span className="leading-6 text-muted-foreground">{uiText(
          "This deployment does not provide an authenticated remote MCP transport. Use a Node accounts deployment or Databricks Apps instead.",
          "この環境では認証済みのリモート MCP transport を提供していません。Node の accounts 環境または Databricks Apps をご利用ください。",
        )}</span>
      </div>}
      {canConfigure && connection?.mcp.databricksProxy && <label className="grid gap-1.5 text-xs font-medium text-muted-foreground">
        <span>{uiText("Databricks profile", "Databricks プロファイル")}</span>
        <Input value={profile} onChange={(event) => { setProfile(event.target.value); setCopyState("idle"); }} spellCheck={false} />
      </label>}
      {canConfigure && <Tabs value={client} onValueChange={(value) => { setClient(value as MCPClient); setCopyState("idle"); }}>
        <TabsList className="grid w-full grid-cols-3" aria-label={uiText("MCP client", "MCP クライアント")}>
          {clients.map((item) => <TabsTrigger key={item.id} value={item.id}>{item.label}</TabsTrigger>)}
        </TabsList>
      </Tabs>}
      {error ? <p className="text-sm text-destructive" role="alert">{error}</p> : !canConfigure ? null : connection ? <>
        <pre className="max-h-64 overflow-auto whitespace-pre-wrap rounded-lg bg-zinc-950 p-4 text-xs leading-5 text-zinc-100"><code>{output}</code></pre>
        <Button type="button" variant="outline" className="w-fit" onClick={() => void copy()}>
          {copyState === "copied" ? uiText("Copied", "コピーしました") : uiText("Copy", "コピー")}
        </Button>
        {copyState === "failed" && <p className="text-sm text-destructive" role="alert">{uiText(
          "Could not copy. Select the settings above and copy them manually.",
          "コピーできませんでした。上の設定を選択して手動でコピーしてください。",
        )}</p>}
      </> : <p className="text-sm text-muted-foreground" role="status">{uiText("Loading MCP settings…", "MCP 設定を読み込み中…")}</p>}
    </div>
    <DialogFooter><Button type="button" onClick={onClose}>{uiText("Done", "完了")}</Button></DialogFooter>
    </DialogContent>
  </Dialog>;
}
