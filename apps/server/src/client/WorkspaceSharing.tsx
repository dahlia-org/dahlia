import { useEffect, useRef, useState } from "react";
import { MenuIcon } from "./Sidebar";
import { Select } from "./Select";
import { apiOperations as api } from "./generated-operations";
import { apiQuery, useLivePage, useLiveQuery } from "./live-data";
import { uiText, workspaceRoleLabel, type SyncedWorkspaceInfo } from "./api";
import type { components } from "./generated-api";
import { Button } from "./components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "./components/ui/dialog";
import { Input } from "./components/ui/input";

type Permission = components["schemas"]["WorkspacePermission"];
type Role = Permission["role"];
type Principal = Permission["principalType"];
const icons = { organization: "organization", team: "members", user: "account" } as const;
const principalLabel = (type: Principal) => type === "organization" ? uiText("Organization", "組織")
  : type === "team" ? uiText("Team", "チーム") : uiText("User", "ユーザー");

export function WorkspaceSharing({ workspace }: { workspace: SyncedWorkspaceInfo }) {
  const personal = workspace.personalUserId != null;
  const editable = workspace.role === "admin" && personal === false;
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [saving, setSaving] = useState(false);
  const pending = useRef(false);
  const trigger = useRef<HTMLButtonElement>(null);
  const [error, setError] = useState<string>();
  useEffect(() => { const timer = setTimeout(() => setQuery(search.trim()), 200); return () => clearTimeout(timer); }, [search]);
  const permissions = useLiveQuery(`sharing:${workspace.workspaceId}`, (signal) => api.listPermissions({ params: { path: { workspaceId: workspace.workspaceId } }, signal }));
  const searchTerm = search.trim();
  const searching = searchTerm.length > 0;
  const resultsCurrent = searching && query === searchTerm;
  const targets = useLivePage(open && query ? apiQuery("searchPermissionTargets", { params: { path: { workspaceId: workspace.workspaceId }, query: { q: query } } }) : undefined);
  async function change(type: Principal, id: string, role: Role | "") {
    if (pending.current || !editable) return;
    pending.current = true;
    setSaving(true);
    setError(undefined);
    try {
      const body = role ? { role } : undefined;
      if (type === "organization") {
        const params = { path: { workspaceId: workspace.workspaceId, organizationId: id } };
        await (body ? api.putOrganizationPermission({ params, body }) : api.deleteOrganizationPermission({ params }));
      } else if (type === "team") {
        const params = { path: { workspaceId: workspace.workspaceId, teamId: id } };
        await (body ? api.putTeamPermission({ params, body }) : api.deleteTeamPermission({ params }));
      } else {
        const params = { path: { workspaceId: workspace.workspaceId, userId: id } };
        await (body ? api.putUserPermission({ params, body }) : api.deleteUserPermission({ params }));
      }
      permissions.reload();
    } catch (caught) { setError(caught instanceof Error ? caught.message : uiText("Could not update sharing", "共有設定を更新できませんでした")); }
    finally { pending.current = false; setSaving(false); }
  }
  const roleOptions = (["viewer", "editor", "admin"] as const).map((role) => <option key={role} value={role}>{workspaceRoleLabel(role)}</option>);
  const rolePicker = (type: Principal, id: string, name: string) => <Select aria-label={uiText(`Access for ${name}`, `${name} のアクセス権`)}
    value={permissions.data?.items.find((p) => p.principalType === type && p.principalId === id)?.role ?? ""}
    disabled={saving || !permissions.data} onValueChange={(value) => void change(type, id, value as Role | "")}>
    <option value="">{uiText("No access", "アクセスなし")}</option>{roleOptions}
  </Select>;
  const close = () => { setOpen(false); setSearch(""); setQuery(""); requestAnimationFrame(() => trigger.current?.focus()); };
  return <section className="mt-9">
    <div className="flex items-center justify-between gap-4 pb-3"><h2 className="text-sm font-semibold">{uiText("Sharing", "共有")}</h2>
      {editable && <Button ref={trigger} size="sm" onClick={() => setOpen(true)}>{uiText("Add access", "共有先を追加")}</Button>}
    </div>
    <p className="text-xs leading-5 text-muted-foreground">{personal ? uiText("Your Personal Workspace is private.", "Personalワークスペースは本人だけが利用できます。")
      : uiText("Admins manage the Workspace; editors change content; viewers can read.", "管理者はワークスペースを管理でき、編集者は内容を変更でき、閲覧者は内容を閲覧できます。")}</p>
    <div className="mt-3 divide-y rounded-lg border px-4">{permissions.data?.items.map((permission) => <div className="flex items-center gap-3 py-3" key={`${permission.principalType}:${permission.principalId}`}>
      <MenuIcon name={icons[permission.principalType]} /><span className="grid min-w-0 flex-1 gap-0.5"><strong className="truncate text-sm">{permission.name ?? permission.principalId}</strong><small className="truncate text-xs text-muted-foreground">{principalLabel(permission.principalType)}{permission.detail ? ` · ${permission.detail}` : ""}</small></span>
      {editable ? rolePicker(permission.principalType, permission.principalId, permission.name ?? permission.principalId) : <span>{workspaceRoleLabel(permission.role)}</span>}
    </div>)}</div>
    <Dialog open={open} onOpenChange={(value) => { if (value) setOpen(true); else close(); }}>
      <DialogContent className="max-w-xl">
      <DialogHeader><DialogTitle>{uiText("Workspace sharing", "ワークスペースの共有")}</DialogTitle>
        <DialogDescription>{uiText("Search organizations, teams, or users to manage access.", "組織・チーム・ユーザーを検索してアクセス権を管理します。")}</DialogDescription></DialogHeader>
      <div className="grid gap-3">
        <Input type="search" aria-label={uiText("Search organizations, teams, or users", "組織・チーム・ユーザーを検索")}
          autoFocus maxLength={200} value={search} onChange={(event) => setSearch(event.target.value)} placeholder={uiText("Name or email", "名前・メールアドレス")} />
        <div className="max-h-[45dvh] divide-y overflow-y-auto" aria-busy={(searching && !resultsCurrent) || targets.loading || saving}>
          {!searching && <p className="py-4 text-sm text-muted-foreground">{uiText("Search by name or email to find a sharing target.", "名前またはメールアドレスを入力して共有先を検索します。")}</p>}
          {searching && (!resultsCurrent || targets.loading) && <p className="py-4 text-sm text-muted-foreground" role="status">{uiText("Searching…", "検索中…")}</p>}
          {resultsCurrent && !targets.loading && targets.data?.items.length === 0 && <p className="py-4 text-sm text-muted-foreground" role="status">{uiText("No matching people or teams.", "該当するユーザーやチームはありません。")}</p>}
          {resultsCurrent && targets.data?.items.map((target) => <div className="flex items-center gap-3 py-3" key={`${target.principalType}:${target.principalId}`}>
            <MenuIcon name={icons[target.principalType]} /><span className="grid min-w-0 flex-1 gap-0.5"><strong className="truncate text-sm">{target.name}</strong><small className="truncate text-xs text-muted-foreground">{principalLabel(target.principalType)} · {target.detail}</small></span>
            {rolePicker(target.principalType, target.principalId, target.name)}
          </div>)}
          {resultsCurrent && targets.data?.nextCursor && <Button variant="outline" size="sm" disabled={targets.loading} onClick={targets.loadMore}>{uiText("Show more", "さらに表示")}</Button>}
        </div>
        {resultsCurrent && targets.error && <p className="text-sm text-destructive" role="alert">{targets.error.message}</p>}
        {error && <p className="text-sm text-destructive" role="alert">{error}</p>}
      </div>
      <DialogFooter><Button onClick={close}>{uiText("Done", "完了")}</Button></DialogFooter>
      </DialogContent>
    </Dialog>
    {(error || permissions.error) && <p className="mt-3 text-sm text-destructive" role="alert">{error || permissions.error?.message}<button className="ml-2 underline" onClick={permissions.reload}>{uiText("Retry", "再試行")}</button></p>}
    {saving && <p className="mt-3 text-sm text-muted-foreground" role="status">{uiText("Updating access…", "アクセス権を更新中…")}</p>}
  </section>;
}
