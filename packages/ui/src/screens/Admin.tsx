import { organizationSlugFromName, organizationSlugPattern } from "../model/organization-slug";
import { DEFAULT_SEARCH_SETTINGS, SEARCH_FIELDS, type SearchSettings, searchSettingsSchema } from "../model/search-settings";
import { apiOperations as api } from "../api/generated-operations";
import { apiQuery, mapQuery, useLiveJSON } from "../api/live-data";
import { type operations } from "../api/generated-api";
import { Select } from "../components/Select";
import { useActionDialog } from "./ActionDialog";
import { useCallback, useEffect, useRef, useState } from "react";
import { navigateDashboard } from "../app/navigation";
import { type OrganizationInfo, uiText } from "../api/api";
import { DetailTabs } from "./MeetingContent";
import { MenuIcon } from "./Sidebar";
import { Button } from "../components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "../components/ui/dialog";
import { Input } from "../components/ui/input";
import { PageHeader } from "../layout/AppShell";
import { type SessionInfo } from "../app/dashboard";
import { DataError } from "./DataError";

type ServerUserRecord = operations["listServerUsers"]["responses"][200]["content"]["application/json"]["items"][number];
type ServerOrganizationRecord = operations["listServerOrganizations"]["responses"][200]["content"]["application/json"]["items"][number];
interface AdminMember {
  id: string;
  name: string;
  email: string;
  role: "admin";
  removable: boolean;
}
function OrganizationCreateDialog({ onClose, onCreated }: { onClose: () => void; onCreated: () => void }) {
  const [ownerOffset, setOwnerOffset] = useState(0);
  const [ownerSearch, setOwnerSearch] = useState("");
  const [ownerQuery, setOwnerQuery] = useState("");
  const owners = useLiveJSON<operations["listServerUsers"]["responses"][200]["content"]["application/json"]>(apiQuery("listServerUsers", { params: { query: { offset: String(ownerOffset), q: ownerQuery || undefined } } }));
  const [ownerId, setOwnerId] = useState("");
  const [name, setName] = useState("");
  const [slug, setSlug] = useState("");
  const [slugEdited, setSlugEdited] = useState(false);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();

  useEffect(() => {
    const items = owners.data?.items;
    if (items) setOwnerId((current) => items.some((owner) => owner.id === current) ? current : "");
  }, [owners.data]);
  useEffect(() => { const timer = setTimeout(() => setOwnerQuery(ownerSearch.trim()), 200); return () => clearTimeout(timer); }, [ownerSearch]);

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (pending || !ownerId) return;
    setPending(true);
    setError(undefined);
    try {
      await api.createOrganization({ body: { name: name.trim(), slug: slug.trim(), initialOwnerUserId: ownerId } });
      onCreated();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : uiText("Could not create organization.", "組織を作成できませんでした。"));
      setPending(false);
    }
  }

  return <Dialog open onOpenChange={(value) => { if (!value && !pending) onClose(); }}>
    <DialogContent onEscapeKeyDown={(event) => { if (pending) event.preventDefault(); }} onPointerDownOutside={(event) => { if (pending) event.preventDefault(); }}>
    <form className="grid gap-5" onSubmit={(event) => void submit(event)} aria-busy={pending}>
      <DialogHeader>
        <DialogTitle className="flex items-center gap-2"><MenuIcon name="organization" />{uiText("Create organization", "組織を新規作成")}</DialogTitle>
        <DialogDescription>{uiText("Create an organization and assign its initial owner.", "組織を作成し、初期オーナーを割り当てます。")}</DialogDescription>
      </DialogHeader>
      <div className="grid gap-4">
        <label className="grid gap-1.5 text-xs font-medium text-muted-foreground"><span>{uiText("Initial owner", "初期オーナー")}</span>
          <Select aria-label={uiText("Initial owner", "初期オーナー")} value={ownerId} placeholder={uiText("Choose an owner", "オーナーを選択")} disabled={pending} onValueChange={setOwnerId}
            emptyMessage={!owners.loading ? uiText("No matching users.", "該当するユーザーはいません。") : undefined}
            search={{ value: ownerSearch, placeholder: uiText("Search by name or email", "名前・メールアドレスで検索"), onValueChange: (value) => { setOwnerSearch(value); setOwnerOffset(0); } }}>
            {owners.data?.items.map((owner) => <option key={owner.id} value={owner.id}>{owner.name} ({owner.email})</option>)}
          </Select>
        </label>
        <DataError error={owners.error} retry={owners.reload} />
        {(ownerOffset > 0 || owners.data?.hasMore) && <div className="flex justify-end gap-2">
          <Button type="button" variant="outline" size="sm" disabled={pending || owners.loading || ownerOffset === 0} onClick={() => setOwnerOffset(ownerOffset - 100)}>{uiText("Previous", "前へ")}</Button>
          <Button type="button" variant="outline" size="sm" disabled={pending || owners.loading || !owners.data?.hasMore} onClick={() => setOwnerOffset(ownerOffset + 100)}>{uiText("Next", "次へ")}</Button>
        </div>}
        <label className="grid gap-1.5 text-xs font-medium text-muted-foreground"><span>{uiText("Name", "名前")}</span><Input name="name" required disabled={pending} value={name} onChange={(event) => { setName(event.target.value); if (!slugEdited) setSlug(organizationSlugFromName(event.target.value)); }} /></label>
        <label className="grid gap-1.5 text-xs font-medium text-muted-foreground"><span>slug</span><Input name="slug" required pattern={organizationSlugPattern.source} disabled={pending} value={slug} onChange={(event) => { setSlug(event.target.value); setSlugEdited(true); }} /></label>
        {error && <p className="text-sm text-destructive" role="alert">{error}</p>}
      </div>
      <DialogFooter>
        <span className="mr-auto self-center text-xs text-muted-foreground" role="status">{pending ? uiText("Creating organization…", "組織を作成中…") : ""}</span>
        <Button type="button" variant="outline" disabled={pending} onClick={onClose}>{uiText("Cancel", "キャンセル")}</Button>
        <Button data-confirm disabled={pending || owners.loading || !ownerId}>{pending ? uiText("Please wait…", "処理中…") : uiText("Create organization", "組織を新規作成")}</Button>
      </DialogFooter>
    </form>
    </DialogContent>
  </Dialog>;
}

export function AdminDirectory({ kind }: { kind: "users" | "organizations" }) {
  const [offset, setOffset] = useState(0);
  const [creating, setCreating] = useState(false);
  const createTrigger = useRef<HTMLButtonElement>(null);
  const query = useLiveJSON<{ items: (ServerUserRecord | ServerOrganizationRecord)[]; hasMore: boolean }>(kind === "users" ? apiQuery("listServerUsers", { params: { query: { offset: String(offset) } } }) : apiQuery("listServerOrganizations", { params: { query: { offset: String(offset) } } }));
  const organizations = kind === "organizations";
  const closeCreate = () => { setCreating(false); requestAnimationFrame(() => createTrigger.current?.focus()); };

  return <>
    {organizations && creating && <OrganizationCreateDialog onClose={closeCreate} onCreated={() => { closeCreate(); query.reload(); }} />}
    <PageHeader title={organizations ? uiText("Organization management", "組織管理") : uiText("User management", "ユーザー管理")}
      description={organizations ? uiText("Organizations on this server, including those you have not joined.", "所属していない組織を含む、サーバー内の組織です。") : uiText("All users registered on this server.", "このサーバーに登録されているすべてのユーザーです。")}
      actions={organizations && <button ref={createTrigger} className="primary" onClick={() => setCreating(true)}><MenuIcon name="plus" />{uiText("Create organization", "組織を新規作成")}</button>} />
    <section className="section-block">
      <DataError error={query.error} retry={query.reload} />
      {query.loading && <p role="status">{uiText("Loading…", "読み込み中…")}</p>}
      {query.data && <><div className="admin-directory-scroll"><table className={`admin-directory${organizations ? " org-directory" : ""}`}>
        <thead><tr><th>{uiText("Name", "名前")}</th><th>{organizations ? "slug" : uiText("Email address", "メールアドレス")}</th><th>{organizations ? uiText("Members", "メンバー") : uiText("Role", "権限")}</th>{organizations && <th>{uiText("Teams", "チーム")}</th>}</tr></thead>
        <tbody>{query.data.items.map((item) => <tr key={item.id}>
          <td>{organizations ? <a className="flex items-center gap-3 py-3 text-[13px] font-medium text-primary hover:underline [&>svg]:shrink-0 [&>svg]:text-muted-foreground [&>strong]:break-words [&>strong]:font-medium" href={`/admin/orgs/${encodeURIComponent(item.id)}`}><MenuIcon name="organization" /><strong>{item.name}</strong></a> : item.name}</td>{"email" in item ? <><td>{item.email}</td><td>{item.role?.split(",").includes("admin") ? uiText("Administrator", "管理者") : uiText("User", "ユーザー")}</td></>
            : <><td><code>{item.slug}</code></td><td>{item.memberCount}</td><td>{item.teamCount}</td></>}
        </tr>)}</tbody>
      </table></div>
      {!query.data.items.length && <p className="muted">{uiText("No results", "該当する項目はありません")}</p>}
      {(offset > 0 || query.data.hasMore) && <div className="admin-pagination">
        <button className="secondary" disabled={query.loading || offset === 0} onClick={() => setOffset(offset - 100)}>{uiText("Previous", "前へ")}</button>
        <button className="secondary" disabled={query.loading || !query.data.hasMore} onClick={() => setOffset(offset + 100)}>{uiText("Next", "次へ")}</button>
      </div>}</>}
    </section>
  </>;
}

export function AdminOrganization({ organizationId, session }: { organizationId: string; session: SessionInfo }) {
  const { dialog, openDialog } = useActionDialog();
  const [membersOffset, setMembersOffset] = useState(0);
  const [teamsOffset, setTeamsOffset] = useState(0);
  const query = useLiveJSON<operations["getServerOrganization"]["responses"][200]["content"]["application/json"]>(apiQuery("getServerOrganization", {
    params: { path: { organizationId }, query: { membersOffset: String(membersOffset), teamsOffset: String(teamsOffset) } },
  }));
  const memberships = useLiveJSON<OrganizationInfo[]>(session.capabilities.sessions ? "/api/auth/organization/list"
    : mapQuery(apiQuery("listOrganizations", {}), ({ items }) => items));
  const organization = query.data;
  const joined = memberships.data?.find((item) => item.id === organizationId);
  const pagination = (offset: number, hasMore: boolean, select: (offset: number) => void) => (offset > 0 || hasMore) && <div className="admin-pagination">
    <button className="secondary" disabled={query.loading || offset === 0} onClick={() => select(offset - 100)}>{uiText("Previous", "前へ")}</button>
    <button className="secondary" disabled={query.loading || !hasMore} onClick={() => select(offset + 100)}>{uiText("Next", "次へ")}</button>
  </div>;
  return <>{dialog}
    <nav className="detail-breadcrumbs" aria-label={uiText("Breadcrumbs", "パンくず")}><a href="/admin/orgs">{uiText("Organization management", "組織管理")}</a></nav>
    <PageHeader title={organization?.name ?? uiText("Organization", "組織")} description={organization?.slug}
      actions={joined && <a className="secondary" href={`/orgs/${encodeURIComponent(joined.id)}`}>{uiText("Manage organization", "組織を管理")}</a>} />
    <DataError error={query.error} retry={query.reload} />
    {query.loading && <p role="status">{uiText("Loading…", "読み込み中…")}</p>}
    {organization && <DetailTabs label={uiText("Organization content", "組織の内容")} tabs={[
      { id: "members", label: uiText("Members", "メンバー"), content: <>
        <div className="admin-directory-scroll"><table className="admin-directory"><thead><tr><th>{uiText("Name", "名前")}</th><th>{uiText("Email address", "メールアドレス")}</th><th>{uiText("Role", "権限")}</th></tr></thead>
          <tbody>{organization.members.map((member) => <tr key={member.id}><td>{member.name}</td><td>{member.email}</td><td>{member.role}</td></tr>)}</tbody>
        </table></div>
        {!organization.members.length && <p className="content-empty">{uiText("No members", "メンバーはいません")}</p>}
        {pagination(membersOffset, organization.hasMoreMembers, setMembersOffset)}
      </> },
      { id: "teams", label: uiText("Teams", "チーム"), content: <>
        <div className="admin-directory-scroll"><table className="admin-directory"><thead><tr><th>{uiText("Name", "名前")}</th></tr></thead>
          <tbody>{organization.teams.map((team) => <tr key={team.id}><td>{team.name}</td></tr>)}</tbody>
        </table></div>
        {!organization.teams.length && <p className="content-empty">{uiText("No teams yet", "チームはまだありません")}</p>}
        {pagination(teamsOffset, organization.hasMoreTeams, setTeamsOffset)}
      </> },
      { id: "settings", label: uiText("Settings", "設定"), content:
        <div className="org-settings"><section className="org-settings-action" aria-label={uiText("Delete organization", "組織を削除")}>
          <div><h3>{uiText("Delete organization", "組織を削除")}</h3><p>{uiText("Delete this organization after removing all owned Workspaces.", "配下のワークスペースをすべて削除した後、この組織を削除できます。")}</p></div>
          <button className="secondary danger-button" onClick={() => openDialog({ title: uiText("Delete organization?", "組織を削除しますか？"), description: uiText("All owned Workspaces must be removed first. Memberships and teams will be deleted.", "配下のワークスペースをすべて削除した後に実行できます。所属とチームを削除します。"), confirmLabel: uiText("Delete", "削除"), destructive: true, onSubmit: async () => { await api.deleteOrganization({ params: { path: { organizationId } } }); navigateDashboard("/admin/orgs"); } })}>{uiText("Delete organization", "組織を削除")}</button>
        </section></div> },
    ]} />}
  </>;
}

export function AdminSearchSettings() {
  const [weights, setWeights] = useState<SearchSettings>();
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);
  const [pending, setPending] = useState(false);
  useEffect(() => {
    let active = true;
    void api.getSearchSettings({}).then((value) => { if (active) setWeights(value); })
      .catch(() => { if (active) setError(uiText("Could not load search settings.", "検索設定を読み込めませんでした。")); });
    return () => { active = false; };
  }, []);
  const labels = { title: uiText("Title", "タイトル"), tags: uiText("Tags", "タグ"), description: uiText("Description", "説明"),
    summary: uiText("Summary", "要約"), ocr: "OCR", caption: uiText("Caption", "キャプション") };
  async function save(event: React.SubmitEvent) {
    event.preventDefault();
    const parsed = searchSettingsSchema.safeParse(weights);
    if (!parsed.success) { setError(uiText("Enter integers from 1 to 10.", "1〜10の整数を入力してください。")); return; }
    setPending(true); setError(""); setSaved(false);
    try { setWeights(await api.updateSearchSettings({ body: parsed.data })); setSaved(true); }
    catch { setError(uiText("Could not save search settings.", "検索設定を保存できませんでした。")); }
    finally { setPending(false); }
  }
  return <>
    <PageHeader title={uiText("Server settings", "サーバー全体の設定")} />
    <section>
      <h2 className="section-label text-[15px] font-semibold text-foreground">{uiText("Search settings", "検索設定")}</h2>
      <p className="muted max-w-[690px] text-[13px] leading-[1.7]">{uiText("Adjust each field's influence on search ranking from 1 to 10. Saved changes apply to subsequent searches across this server.", "各項目が検索順位に与える影響を1〜10で調整します。保存後の検索からサーバー全体に反映されます。")}</p>
      {!weights && !error && <p role="status">{uiText("Loading…", "読み込み中…")}</p>}
      {weights && <form className="panel admin-form search-settings-form" onSubmit={(event) => void save(event)}>
        {SEARCH_FIELDS.map((field) => <label key={field}>{labels[field]}<span className="search-weight-slider"><input type="range" min={1} max={10} step={1} disabled={pending}
          value={weights[field]} onChange={(event) => { setWeights({ ...weights, [field]: event.target.valueAsNumber }); setSaved(false); }} /><span aria-hidden="true">{weights[field]}</span></span></label>)}
        <button className="primary" disabled={pending}>{pending ? uiText("Saving…", "保存中…") : uiText("Save", "保存")}</button>
        <button type="button" className="secondary" disabled={pending} onClick={() => { setWeights({ ...DEFAULT_SEARCH_SETTINGS }); setSaved(false); setError(""); }}>{uiText("Reset to defaults", "初期値に戻す")}</button>
      </form>}
      {error && <p className="error" role="alert">{error}</p>}
      {saved && <p role="status">{uiText("Search settings saved.", "検索設定を保存しました。")}</p>}
    </section>
  </>;
}

export function AdminMembers() {
  const { dialog, openDialog } = useActionDialog();
  const [members, setMembers] = useState<AdminMember[]>();
  const [email, setEmail] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const load = useCallback(() => {
    setError(undefined);
    void api.listAdministrators({}).then(({ items }) => setMembers(items)).catch((caught: Error) => setError(caught.message));
  }, []);
  useEffect(load, [load]);

  async function add(event: React.FormEvent) {
    event.preventDefault();
    if (pending) return;
    setPending(true);
    setError(undefined);
    try {
      await api.addAdministrator({ body: { email } });
      setEmail("");
      load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not add administrator");
    } finally {
      setPending(false);
    }
  }

  function remove(member: AdminMember) {
    openDialog({
      title: uiText("Remove administrator?", "管理者権限を解除しますか？"),
      description: uiText(`${member.email} will lose administrator access. Their personal account and meetings will remain.`, `${member.email} の管理者権限を解除します。個人アカウントとミーティングは残ります。`),
      confirmLabel: uiText("Remove access", "権限を解除"), destructive: true,
      onSubmit: async () => { await api.removeAdministrator({ params: { path: { userId: member.id } } }); load(); },
    });
  }

  return (
    <>
      {dialog}
      <section className="section-block">
        <h2 className="section-label">{uiText("Administrators", "管理者")}</h2>
        <div className="panel admin-list">
          {!members && !error && <p className="muted">{uiText("Loading administrators…", "管理者を読み込み中…")}</p>}
          {members?.length === 0 && <div className="empty-state"><strong>{uiText("No administrators", "管理者はいません")}</strong><span>{uiText("Add an email below.", "メールアドレスを入力して追加してください。")}</span></div>}
          {members?.map((member) => (
            <div className="admin-row member-row" key={member.id}>
              <div><strong>{member.email}</strong><span>{member.name} · Admin</span></div>
              <button className="secondary danger-button" disabled={!member.removable} onClick={() => remove(member)}>{uiText("Remove", "解除")}</button>
            </div>
          ))}
        </div>
      </section>
      <section className="section-block">
        <h2 className="section-label">{uiText("Add administrator", "管理者を追加")}</h2>
        <form className="panel admin-form member-form" onSubmit={(event) => void add(event)}>
          <label>{uiText("Email", "メールアドレス")}<input type="email" value={email} required placeholder="admin@example.com" onChange={(event) => setEmail(event.target.value)} /></label>
          <button className="primary" disabled={pending}>{pending ? uiText("Adding…", "追加中…") : uiText("Add administrator", "管理者を追加")}</button>
        </form>
      </section>
      {error && <p className="error -mt-3.5 mb-5">{error}</p>}
    </>
  );
}
