import { useEffect, useId, useRef, useState } from "react";
import { MenuIcon, useSidebar } from "./Sidebar";
import { apiOperations as api } from "./generated-operations";
import { apiQuery, useLivePage, useLiveQuery } from "./live-data";
import { uiText, vaultRoleLabel, type SyncedVaultInfo } from "./api";
import type { components } from "./generated-api";

type Permission = components["schemas"]["VaultPermission"];
type Role = Permission["role"];
type Principal = Permission["principalType"];
const icons = { organization: "organization", team: "members", user: "account" } as const;
const principalLabel = (type: Principal) => type === "organization" ? uiText("Organization", "組織")
  : type === "team" ? uiText("Team", "チーム") : uiText("User", "ユーザー");

export function VaultSharing({ vault }: { vault: SyncedVaultInfo }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  const { organizations } = useSidebar();
  const personal = organizations?.some((organization) => organization.id === vault.organizationId && organization.kind === "personal");
  const editable = vault.role === "admin" && personal === false;
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [saving, setSaving] = useState(false);
  const pending = useRef(false);
  const [error, setError] = useState<string>();
  const [principal, setPrincipal] = useState<Principal>("user");
  const [knownId, setKnownId] = useState("");
  const [newRole, setNewRole] = useState<Role>("viewer");
  useEffect(() => { const timer = setTimeout(() => setQuery(search.trim()), 200); return () => clearTimeout(timer); }, [search]);
  const permissions = useLiveQuery(`sharing:${vault.vaultId}`, (signal) => api.listPermissions({ params: { path: { vaultId: vault.vaultId } }, signal }));
  const targets = useLivePage(open ? apiQuery("searchPermissionTargets", { params: { path: { vaultId: vault.vaultId }, query: { q: query } } }) : undefined);
  async function change(type: Principal, id: string, role: Role | "") {
    if (pending.current || !editable) return;
    pending.current = true;
    setSaving(true);
    setError(undefined);
    try {
      const body = role ? { role } : undefined;
      if (type === "organization") {
        const params = { path: { vaultId: vault.vaultId, organizationId: id } };
        await (body ? api.putOrganizationPermission({ params, body }) : api.deleteOrganizationPermission({ params }));
      } else if (type === "team") {
        const params = { path: { vaultId: vault.vaultId, teamId: id } };
        await (body ? api.putTeamPermission({ params, body }) : api.deleteTeamPermission({ params }));
      } else {
        const params = { path: { vaultId: vault.vaultId, userId: id } };
        await (body ? api.putUserPermission({ params, body }) : api.deleteUserPermission({ params }));
      }
      permissions.reload();
    } catch (caught) { setError(caught instanceof Error ? caught.message : uiText("Could not update sharing", "共有設定を更新できませんでした")); }
    finally { pending.current = false; setSaving(false); }
  }
  const roleOptions = <>{(["viewer", "editor", "admin"] as const).map((role) => <option key={role} value={role}>{vaultRoleLabel(role)}</option>)}</>;
  const rolePicker = (type: Principal, id: string, name: string) => <select aria-label={uiText(`Access for ${name}`, `${name} のアクセス権`)}
    value={permissions.data?.items.find((p) => p.principalType === type && p.principalId === id)?.role ?? ""}
    disabled={saving || !permissions.data} onChange={(event) => void change(type, id, event.target.value as Role | "")}>
    <option value="">{uiText("No access", "アクセスなし")}</option>{roleOptions}
  </select>;
  return <section className="section-block">
    <div className="collection-heading"><h2>{uiText("Sharing", "共有")}</h2>
      {editable && <button className="primary" onClick={() => { setOpen(true); dialog.current?.showModal(); }}>{uiText("Add access", "共有先を追加")}</button>}
    </div>
    <p className="muted">{personal ? uiText("Your Personal Vault is private.", "Personal保管庫は本人だけが利用できます。")
      : uiText("Admins manage the Vault; editors change content; viewers can read.", "管理者は保管庫を管理でき、編集者は内容を変更でき、閲覧者は内容を閲覧できます。")}</p>
    <div className="share-list">{permissions.data?.items.map((permission) => <div className="share-row" key={`${permission.principalType}:${permission.principalId}`}>
      <MenuIcon name={icons[permission.principalType]} /><span><strong>{permission.name ?? permission.principalId}</strong><small>{principalLabel(permission.principalType)}{permission.detail ? ` · ${permission.detail}` : ""}</small></span>
      {editable ? rolePicker(permission.principalType, permission.principalId, permission.name ?? permission.principalId) : <span>{vaultRoleLabel(permission.role)}</span>}
    </div>)}</div>
    <dialog ref={dialog} className="action-dialog sharing-dialog" aria-labelledby={titleId} onClose={() => setOpen(false)}>
      <header className="dialog-header"><h2 id={titleId}>{uiText("Vault sharing", "保管庫の共有")}</h2></header>
      <div className="dialog-body">
        <input type="search" aria-label={uiText("Search organizations, teams, or users", "組織・チーム・ユーザーを検索")}
          autoFocus maxLength={200} value={search} onChange={(event) => setSearch(event.target.value)} placeholder={uiText("Name or email", "名前・メールアドレス")} />
        <div className="share-list sharing-results" aria-busy={targets.loading || saving}>
          {targets.loading && <p role="status">{uiText("Searching…", "検索中…")}</p>}
          {targets.data?.items.map((target) => <div className="share-row" key={`${target.principalType}:${target.principalId}`}>
            <MenuIcon name={icons[target.principalType]} /><span><strong>{target.name}</strong><small>{principalLabel(target.principalType)} · {target.detail}</small></span>
            {rolePicker(target.principalType, target.principalId, target.name)}
          </div>)}
          {targets.data?.nextCursor && <button className="secondary" disabled={targets.loading} onClick={targets.loadMore}>{uiText("Show more", "さらに表示")}</button>}
        </div>
        <form onSubmit={(event) => { event.preventDefault(); void change(principal, knownId.trim(), newRole); }}>
          <h3>{uiText("Share by ID", "IDを指定して共有")}</h3>
          <select aria-label={uiText("Principal type", "共有先の種類")} value={principal} onChange={(event) => setPrincipal(event.target.value as Principal)}>
            {(["user", "organization", "team"] as const).map((type) => <option key={type} value={type}>{principalLabel(type)}</option>)}
          </select>
          <input required aria-label={uiText("Known ID", "共有先のID")} value={knownId} onChange={(event) => setKnownId(event.target.value)} />
          <select aria-label={uiText("Role", "権限")} value={newRole} onChange={(event) => setNewRole(event.target.value as Role)}>{roleOptions}</select>
          <button className="secondary" disabled={saving || !knownId.trim()}>{uiText("Grant access", "アクセスを許可")}</button>
        </form>
        {targets.error && <p role="alert">{targets.error.message}</p>}
        {error && <p role="alert">{error}</p>}
      </div>
      <footer className="dialog-footer"><button className="primary" onClick={() => dialog.current?.close()}>{uiText("Done", "完了")}</button></footer>
    </dialog>
    {(error || permissions.error) && <p className="error" role="alert">{error || permissions.error?.message}<button onClick={permissions.reload}>{uiText("Retry", "再試行")}</button></p>}
    {saving && <p role="status">{uiText("Updating access…", "アクセス権を更新中…")}</p>}
  </section>;
}
