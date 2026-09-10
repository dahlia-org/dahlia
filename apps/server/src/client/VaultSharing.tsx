import { useEffect, useId, useRef, useState } from "react";
import { MenuIcon } from "./Sidebar";
import { apiOperations as api } from "./generated-operations";
import { apiQuery, useLivePage, useLiveQuery } from "./live-data";
import { json, uiText, type SyncedVaultInfo, type OrganizationInfo } from "./api";

import type { components } from "./generated-api";
type VaultPermissionInfo = components["schemas"]["VaultPermission"];
const principalIcons = { organization: "organization", team: "members", user: "account" } as const;

export function VaultSharing({ vault, accounts = false }: { vault: SyncedVaultInfo; accounts?: boolean }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [saving, setSaving] = useState(false);
  const pending = useRef(false);
  const [error, setError] = useState<string>();
  useEffect(() => { const timer = setTimeout(() => setQuery(search.trim()), 200); return () => clearTimeout(timer); }, [search]);
  const permissions = useLiveQuery(`sharing:${vault.vaultId}`, (signal) => api.listPermissions({ params: { path: { vaultId: vault.vaultId } }, signal }));
  const labels = useLiveQuery(vault.role === "member" ? `sharing-labels:${vault.vaultId}:${accounts}` : undefined, async (signal) => {
    const organizations = accounts ? await json<OrganizationInfo[]>("/api/auth/organization/list", { signal })
      : (await api.listOrganizations({ signal })).items;
    const teams = (await Promise.all(organizations.map(async (organization) => accounts
      ? json<Array<{ id: string; name: string }>>(`/api/auth/organization/list-teams?organizationId=${encodeURIComponent(organization.id)}`, { signal })
      : (await api.listTeams({ params: { path: { organizationId: organization.id } }, signal })).items))).flat();
    return { organizations, teams };
  });
  const targets = useLivePage(open ? apiQuery("searchPermissionTargets", {
    params: { path: { vaultId: vault.vaultId }, query: { q: query } },
  }) : undefined);
  const shared = (type: VaultPermissionInfo["principalType"], id: string) => permissions.data?.items.some((p) => p.role === "member" && p.principalType === type && p.principalId === id) === true;
  async function toggle(type: VaultPermissionInfo["principalType"], id: string, enabled: boolean) {
    if (pending.current) return;
    pending.current = true;
    setSaving(true);
    setError(undefined);
    try {
      if (type === "organization") {
        const params = { path: { vaultId: vault.vaultId, organizationId: id } };
        await (enabled ? api.putOrganizationPermission({ params }) : api.deleteOrganizationPermission({ params }));
      } else if (type === "team") {
        const params = { path: { vaultId: vault.vaultId, teamId: id } };
        await (enabled ? api.putTeamPermission({ params }) : api.deleteTeamPermission({ params }));
      } else {
        const params = { path: { vaultId: vault.vaultId, userId: id } };
        await (enabled ? api.putUserPermission({ params }) : api.deleteUserPermission({ params }));
      }
      permissions.reload();
    } catch (caught) { setError(caught instanceof Error ? caught.message : uiText("Could not update sharing", "共有設定を更新できませんでした")); }
    finally { pending.current = false; setSaving(false); }
  }
  function principalLabel(type: VaultPermissionInfo["principalType"]) {
    switch (type) {
      case "organization": return uiText("Organization", "組織");
      case "team": return uiText("Team", "チーム");
      case "user": return uiText("User", "ユーザー");
    }
  }
  function permissionLabel(permission: VaultPermissionInfo) {
    if (permission.principalType === "user") return uiText("Shared directly with you", "あなたに直接共有");
    const principals = permission.principalType === "organization" ? labels.data?.organizations : labels.data?.teams;
    return principals?.find(({ id }) => id === permission.principalId)?.name ?? principalLabel(permission.principalType);
  }
  return <section className="section-block">
    <h2 className="section-label">{uiText("Sharing", "共有")}</h2>
    {vault.role === "owner" ? <>
      <div className="collection-heading">
      <p className="muted">{uiText("Share read-only access with organizations, teams, or people.", "組織・チーム・ユーザーに閲覧権限を共有できます。")}</p>
      <button className="primary" onClick={() => { setOpen(true); dialog.current?.showModal(); }}>{uiText("Manage sharing", "共有を設定")}</button>
      </div>
      <dialog ref={dialog} className="action-dialog sharing-dialog" aria-labelledby={titleId} onClose={() => setOpen(false)}>
        <header className="dialog-header"><h2 id={titleId}>{uiText("Vault sharing", "保管庫の共有")}</h2></header>
        <div className="dialog-body">
        <p className="muted">{uiText("Changes apply immediately. Access is read-only.", "変更はすぐに反映されます。共有先は閲覧のみ可能です。")}</p>
        <input type="search" aria-label={uiText("Search organizations, teams, or users", "組織・チーム・ユーザーを検索")}
          autoFocus maxLength={200} value={search} onChange={(event) => setSearch(event.target.value)} placeholder={uiText("Name or email", "名前・メールアドレス")} />
        <div className="share-list sharing-results" aria-busy={targets.loading || saving}>
          {targets.loading && <p role="status">{uiText("Searching…", "検索中…")}</p>}
          {targets.data?.items.map((target) => <label className="share-row" key={`${target.principalType}:${target.principalId}`}>
            <MenuIcon name={principalIcons[target.principalType]} />
            <span><strong>{target.name}</strong><small>{principalLabel(target.principalType)} · {target.detail}</small></span>
            <input type="checkbox" checked={shared(target.principalType, target.principalId)} disabled={saving || permissions.loading || !permissions.data || targets.loading}
              onChange={(event) => void toggle(target.principalType, target.principalId, event.target.checked)} />
          </label>)}
          {!targets.loading && targets.data?.items.length === 0 && <p className="muted">{uiText("No matching sharing targets", "一致する共有先がありません")}</p>}
          {targets.data?.nextCursor && <button className="secondary" disabled={targets.loading} onClick={targets.loadMore}>{uiText("Show more", "さらに表示")}</button>}
        </div>
        {(error || targets.error || permissions.error) && <p className="error" role="alert">{error || targets.error?.message || permissions.error?.message}</p>}
        {(targets.error || permissions.error) && <button onClick={() => { targets.reload(); permissions.reload(); }}>{uiText("Retry", "再試行")}</button>}
        {saving && <p role="status">{uiText("Updating access…", "アクセス権を更新中…")}</p>}
        </div>
        <footer className="dialog-footer"><button className="primary" onClick={() => dialog.current?.close()}>{uiText("Done", "完了")}</button></footer>
      </dialog>
    </> : <>
      <p className="muted">{uiText("This Vault was shared with you. Only its owner can change access.", "共有された保管庫です。アクセス権は所有者のみ変更できます。")}</p>
      <div className="panel share-list">{permissions.data?.items.map((permission) => <div className="share-row" key={`${permission.principalType}:${permission.principalId}`}>
        <span><strong>{permissionLabel(permission)}</strong>
          <small>{uiText("Read-only access", "閲覧のみ")}</small></span>
      </div>)}</div>
      {(permissions.error || labels.error) && <p className="error" role="alert">{permissions.error?.message || labels.error?.message}<button className="secondary" onClick={() => { permissions.reload(); labels.reload(); }}>{uiText("Retry", "再試行")}</button></p>}
    </>}
  </section>;
}
