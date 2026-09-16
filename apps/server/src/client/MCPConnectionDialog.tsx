import { useEffect, useId, useRef, useState } from "react";

import { json, uiText } from "./api";

export type MCPClient = "mcpJSON" | "claude" | "codex";

interface MCPConnectionInfo {
  mcp: { url: string; databricksProxy: boolean; available: boolean };
}

export function parseMCPConnectionInfo(value: unknown): MCPConnectionInfo {
  const mcp = typeof value === "object" && value !== null && "mcp" in value ? value.mcp : undefined;
  if (typeof mcp === "object" && mcp !== null && "url" in mcp && typeof mcp.url === "string"
    && "databricksProxy" in mcp && typeof mcp.databricksProxy === "boolean"
    && "available" in mcp && typeof mcp.available === "boolean") {
    try {
      const protocol = new URL(mcp.url).protocol;
      if (protocol === "http:" || protocol === "https:") return { mcp: { url: mcp.url, databricksProxy: mcp.databricksProxy, available: mcp.available } };
    } catch { /* Report the same invalid-response error below. */ }
  }
  throw new Error(uiText("The Server returned invalid MCP settings", "Server から無効な MCP 設定が返されました"));
}

function shellArgument(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

export function mcpConnectionOutput(client: MCPClient, url: string, databricksProxy: boolean, profile = "DEFAULT"): string {
  const normalizedProfile = profile.trim() || "DEFAULT";
  if (client === "mcpJSON") {
    return JSON.stringify({
      mcpServers: {
        dahlia: databricksProxy
          ? { type: "stdio", command: "uvx", args: ["uc-mcp-proxy", "--url", url, "--profile", normalizedProfile] }
          : { type: "http", url },
      },
    }, null, 2);
  }
  if (databricksProxy) {
    const command = `uvx uc-mcp-proxy --url ${shellArgument(url)} --profile ${shellArgument(normalizedProfile)}`;
    return client === "claude"
      ? `claude mcp add --scope user dahlia -- ${command}`
      : `codex mcp add dahlia -- ${command}`;
  }
  return client === "claude"
    ? `claude mcp add --scope user --transport http dahlia ${shellArgument(url)}`
    : `codex mcp add dahlia --url ${shellArgument(url)}`;
}

const clients: Array<{ id: MCPClient; label: string }> = [
  { id: "mcpJSON", label: "mcp.json" },
  { id: "claude", label: "Claude Code" },
  { id: "codex", label: "Codex" },
];

export function MCPConnectionDialog({ onClose }: { onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [connection, setConnection] = useState<MCPConnectionInfo>();
  const [error, setError] = useState<string>();
  const [client, setClient] = useState<MCPClient>("mcpJSON");
  const [profile, setProfile] = useState("DEFAULT");
  const [copyState, setCopyState] = useState<"idle" | "copied" | "failed">("idle");
  const titleId = useId();

  useEffect(() => {
    const previous = document.activeElement;
    const element = dialog.current!;
    const controller = new AbortController();
    element.showModal();
    element.querySelector<HTMLElement>("[data-close]")?.focus();
    void json<unknown>("/api/auth/mode", { signal: controller.signal })
      .then((value) => setConnection(parseMCPConnectionInfo(value)))
      .catch((caught: unknown) => {
        if (!controller.signal.aborted) setError(caught instanceof Error ? caught.message : uiText("Could not load MCP settings", "MCP 設定を読み込めませんでした"));
      });
    return () => {
      controller.abort();
      element.close();
      if (previous instanceof HTMLElement && previous.isConnected) previous.focus({ preventScroll: true });
    };
  }, []);

  const mcpUnavailable = connection?.mcp.available === false;
  const canConfigure = !error && !mcpUnavailable;
  const output = connection ? mcpConnectionOutput(client, connection.mcp.url, connection.mcp.databricksProxy, profile) : "";
  async function copy() {
    try {
      await navigator.clipboard.writeText(output);
      setCopyState("copied");
      window.setTimeout(() => setCopyState("idle"), 2000);
    } catch {
      setCopyState("failed");
    }
  }

  return <dialog ref={dialog} className="action-dialog action-dialog-wide mcp-connection-dialog" aria-labelledby={titleId}
    onCancel={(event) => { event.preventDefault(); onClose(); }}
    onClick={(event) => { if (event.target === event.currentTarget) onClose(); }}>
    <header className="dialog-header">
      <div><span className="dialog-symbol" aria-hidden="true">⌁</span><h2 id={titleId}>{uiText("Connect with MCP", "MCP による接続")}</h2></div>
      <button type="button" className="icon-button" data-close aria-label={uiText("Close", "閉じる")} onClick={onClose}>×</button>
    </header>
    <div className="dialog-body mcp-dialog-body">
      <p className="dialog-description">{uiText(
        "Connect an MCP client to search and read meetings in the Workspaces you can access.",
        "アクセスできるワークスペースのミーティングを検索・参照できるよう、MCP クライアントを接続します。",
      )}</p>
      {connection?.mcp.databricksProxy && <div className="mcp-proxy-note">
        <strong>{uiText("Databricks Apps authentication", "Databricks Apps の認証")}</strong>
        <span>{uiText(
          "This deployment connects through uvx uc-mcp-proxy. Install uv and configure a Databricks CLI profile first; an expired OAuth profile opens browser login automatically.",
          "この環境では uvx uc-mcp-proxy を経由します。事前に uv を用意し、Databricks CLI プロファイルを設定してください。OAuth の期限切れ時はブラウザ認証が自動で開きます。",
        )}</span>
      </div>}
      {mcpUnavailable && <div className="mcp-unavailable-note" role="status">
        <strong>{uiText("MCP setup is unavailable in this deployment", "この環境では MCP 接続を設定できません")}</strong>
        <span>{uiText(
          "This deployment does not provide an authenticated remote MCP transport. Use a Node accounts deployment or Databricks Apps instead.",
          "この環境では認証済みのリモート MCP transport を提供していません。Node の accounts 環境または Databricks Apps をご利用ください。",
        )}</span>
      </div>}
      {canConfigure && connection?.mcp.databricksProxy && <label className="mcp-profile-field">
        <span>{uiText("Databricks profile", "Databricks プロファイル")}</span>
        <input value={profile} onChange={(event) => { setProfile(event.target.value); setCopyState("idle"); }} spellCheck={false} />
      </label>}
      {canConfigure && <div className="mcp-client-tabs" role="group" aria-label={uiText("MCP client", "MCP クライアント")}>
        {clients.map((item) => <button type="button" key={item.id} aria-pressed={client === item.id}
          onClick={() => { setClient(item.id); setCopyState("idle"); }}>{item.label}</button>)}
      </div>}
      {error ? <p className="dialog-error" role="alert">{error}</p> : !canConfigure ? null : connection ? <>
        <pre className="mcp-connection-output"><code>{output}</code></pre>
        <button type="button" className="secondary mcp-copy-button" onClick={() => void copy()}>
          {copyState === "copied" ? uiText("Copied", "コピーしました") : uiText("Copy", "コピー")}
        </button>
        {copyState === "failed" && <p className="dialog-error" role="alert">{uiText(
          "Could not copy. Select the settings above and copy them manually.",
          "コピーできませんでした。上の設定を選択して手動でコピーしてください。",
        )}</p>}
      </> : <p className="muted" role="status">{uiText("Loading MCP settings…", "MCP 設定を読み込み中…")}</p>}
    </div>
    <footer className="dialog-footer"><button type="button" className="primary" onClick={onClose}>{uiText("Done", "完了")}</button></footer>
  </dialog>;
}
