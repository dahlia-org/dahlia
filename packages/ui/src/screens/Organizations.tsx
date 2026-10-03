import { objectPath } from "../model/object-url";
import { organizationSlugPattern } from "../model/organization-slug";
import { encodeId } from "../model/typeid";
import { apiOperations as api } from "../api/generated-operations";
import { type components, type operations } from "../api/generated-api";
import { apiQuery, useLiveJSON, useLivePage } from "../api/live-data";
import { AppearanceIcon, collectionAppearance } from "./AppearancePicker";
import { useActionDialog } from "./ActionDialog";
import { useCallback, useEffect, useMemo, useState } from "react";
import { navigateDashboard } from "../app/navigation";
import { json, type OrganizationInfo, syncMessage, uiText } from "../api/api";
import { DetailTabs } from "./MeetingContent";
import { MenuIcon, useSidebar } from "./Sidebar";
import { PageHeader } from "../layout/AppShell";
import { Checkbox } from "../components/ui/checkbox";
import { type SessionInfo } from "../app/dashboard";
import { createWorkspaceRecord } from "../api/transactions";
import { workspaceEncryptionFields } from "./Workspaces";
import { DataError } from "./DataError";
import { uuidV7 } from "../model/id";

interface OrganizationMember {
  id: string;
  userId: string;
  role: string;
  user: { name: string; email: string };
}

interface OrganizationInvitation {
  id: string;
  organizationId: string;
  organizationName?: string;
  email: string;
  role: string;
  status: string;
  expiresAt: string;
}

interface TeamInfo {
  id: string;
  name: string;
  organizationId: string;
}

interface TeamMember {
  id: string;
  userId: string;
  teamId: string;
}
function OrganizationWorkspaces({ organization }: { organization: OrganizationInfo }) {
  const query = useLivePage<components["schemas"]["GovernanceWorkspace"]>(apiQuery("listGovernanceWorkspaces", { params: { path: { organizationId: organization.id } } }));
  const { workspaces } = useSidebar();
  const { dialog, openDialog } = useActionDialog();
  const encryptionCapabilities = useLiveJSON<{ workspaceEncryption?: { version: number } }>(apiQuery("getCapabilities", {}));
  const [recovering, setRecovering] = useState(false);
  const [error, setError] = useState<string>();
  function createWorkspace() {
    openDialog({ title: uiText("New Workspace", "ワークスペースを作成"),
      description: uiText(`Create a Workspace owned by “${organization.name}”. Sharing is configured after creation.`, `「${organization.name}」が所有するワークスペースを作成します。共有は作成後に設定できます。`),
      confirmLabel: uiText("Create Workspace", "ワークスペースを作成"),
      fields: [{ name: "name", label: uiText("Workspace name", "ワークスペース名"), required: true },
        ...workspaceEncryptionFields(Boolean(encryptionCapabilities.data?.workspaceEncryption))],
      onSubmit: async ({ name, encryption }) => {
        const id = await createWorkspaceRecord(organization.id, name!, encryption, setRecovering);
        navigateDashboard(objectPath(id));
      },
    });
  }
  async function confirm(workspaceId: string) {
    setError(undefined);
    try {
      const current = await api.confirmWorkspaceDeletion({ params: { path: { organizationId: organization.id, workspaceId } } });
      const id = encodeId("transaction", uuidV7());
      openDialog({ title: uiText("Delete Workspace and all content?", "ワークスペースとすべての内容を削除しますか？"),
        description: uiText(`Permanently delete “${current.name}” and all its meetings, files and recordings. This cannot be undone.`, `「${current.name}」と、配下のすべての会議・ファイル・録音を削除します。この操作は取り消せません。`),
        confirmLabel: uiText("Delete all content", "すべて削除"), destructive: true,
        onSubmit: async () => {
          await api.forceDeleteWorkspace({ params: { path: { organizationId: organization.id, workspaceId } }, body: { id, revision: current.revision, changeCursor: current.changeCursor } });
          query.reload();
        },
      });
    } catch (caught) { setError(caught instanceof Error ? caught.message : String(caught)); }
  }
  return <section>{dialog}
    <div className="org-section-header"><p>{uiText("Organization governance shows Workspace metadata. Content requires a separate Workspace permission.", "組織の管理用情報を表示しています。内容の閲覧にはワークスペースのアクセス権が必要です。")}</p>
      <button className="primary" disabled={!encryptionCapabilities.data} onClick={createWorkspace}><MenuIcon name="plus" />{uiText("New Workspace", "ワークスペースを作成")}</button>
    </div>
    <DataError error={encryptionCapabilities.error} retry={encryptionCapabilities.reload} />
    {recovering && <p role="status">{syncMessage("sync_recovering")}</p>}
    {query.data?.items.map((workspace) => <div className="row" key={workspace.workspaceId}>
      {workspaces?.some(({ workspaceId }) => workspaceId === workspace.workspaceId)
        ? <a className="flex min-w-0 flex-1 items-center gap-2 hover:text-primary hover:underline" href={objectPath(workspace.workspaceId)}><AppearanceIcon appearance={collectionAppearance(workspace, "workspace")} /><strong>{workspace.name}</strong></a>
        : <div className="flex min-w-0 flex-1 flex-row items-center gap-2"><AppearanceIcon appearance={collectionAppearance(workspace, "workspace")} /><strong>{workspace.name}</strong></div>}
      {<button className="secondary danger-button" onClick={() => void confirm(workspace.workspaceId)}>{uiText("Delete", "削除")}</button>}
    </div>)}
    {query.data?.items.length === 0 && <p>{uiText("No Workspaces", "ワークスペースがありません")}</p>}
    {query.data?.nextCursor && <button onClick={query.loadMore}>{uiText("Show more", "さらに表示")}</button>}
    <DataError error={query.error} retry={query.reload} />{error && <p role="alert">{error}</p>}
  </section>;
}

function joinPolicyLabel(policy: string) {
  switch (policy) {
    case "auto_join": return uiText("Auto join", "自動参加");
    case "need_approval": return uiText("Approval required", "承認制");
    default: return uiText("Invitation only", "招待のみ");
  }
}

function joinPolicyDescription(policy: string) {
  switch (policy) {
    case "auto_join": return uiText("New users join automatically when they first register. Existing users can join from the organization list.", "初回登録時に自動参加します。登録済みユーザーは所属組織から参加できます。");
    case "need_approval": return uiText("Users with this email domain can request access. An owner or administrator must approve.", "同じメールドメインのユーザーが参加申請できます。所有者または管理者の承認が必要です。");
    default: return uiText("Only users invited by an owner or administrator can join.", "所有者または管理者から招待されたユーザーだけが参加できます。");
  }
}

function joinPolicyOptionLabel(policy: string) {
  switch (policy) {
    case "auto_join": return uiText("Auto join — on first registration", "自動参加 — 初回登録時に参加");
    case "need_approval": return uiText("Approval required — review each request", "承認制 — 参加申請を確認");
    default: return uiText("Invitation only — invite required", "招待のみ — 管理者からの招待が必要");
  }
}

function OrganizationDomains({ organizationId, canManage }: { organizationId: string; canManage: boolean }) {
  const query = useLiveJSON(apiQuery("getOrganizationDomains", { params: { path: { organizationId } } }));
  const { dialog, openDialog } = useActionDialog();
  function edit(index?: number) {
    const current = index === undefined ? undefined : query.data!.domains[index];
    openDialog({ title: current ? uiText("Edit email domain", "メールドメインを編集") : uiText("Add email domain", "メールドメインを追加"),
      description: uiText("Choose how users with this verified email domain can join. Existing memberships will not change.", "確認済みメールがこのドメインと一致するユーザーの参加方法を設定します。既存の所属は変わりません。"),
      confirmLabel: current ? uiText("Save changes", "変更を保存") : uiText("Add domain", "ドメインを追加"),
      fields: [{ name: "domain", label: uiText("Domain", "ドメイン"), value: current?.domain ?? "", required: true },
        { name: "joinPolicy", label: uiText("How users join", "参加方法"), value: current?.joinPolicy ?? "invite_only", options: ["invite_only", "need_approval", "auto_join"].map((value) => ({ value, label: joinPolicyOptionLabel(value) })) }],
      onSubmit: async ({ domain, joinPolicy }) => {
        const domains = [...query.data!.domains];
        const row = { domain: domain!, joinPolicy: joinPolicy as "invite_only" | "need_approval" | "auto_join" };
        if (index === undefined) domains.push(row); else domains[index] = row;
        await api.updateOrganizationDomains({ params: { path: { organizationId } }, body: { domains } });
      },
    });
  }
  function remove(index: number) {
    const domain = query.data!.domains[index]!.domain;
    openDialog({ title: uiText("Remove email domain?", "メールドメインを削除しますか？"),
      description: uiText(`${domain} will no longer provide a way to join this organization. Existing memberships will not change.`, `${domain} を使った新しい参加ができなくなります。既存の所属は変わりません。`),
      confirmLabel: uiText("Remove domain", "ドメインを削除"), destructive: true,
      onSubmit: async () => { await api.updateOrganizationDomains({ params: { path: { organizationId } }, body: { domains: query.data!.domains.filter((_, i) => i !== index) } }); } });
  }
  return <section className="org-domain-settings" aria-label={uiText("Email domain access", "メールドメインによる参加")}>
    {dialog}<header className="org-domain-header"><div><span className="org-domain-kicker">{uiText("Member access", "メンバー参加")}</span>
      <h3>{uiText("Email domain access", "メールドメインによる参加")}</h3>
      <p>{uiText("Set how people with a matching verified email address can join this organization.", "確認済みメールが一致するユーザーの参加方法を、ドメインごとに設定します。")}</p></div>
      {canManage && query.data && query.data.domains.length < 10 && <button className="primary" onClick={() => edit()}><MenuIcon name="plus" />{uiText("Add domain", "ドメインを追加")}</button>}
    </header>
    {query.loading && <p className="org-domain-loading" role="status">{uiText("Loading email domains…", "メールドメインを読み込み中…")}</p>}
    {query.data && <><div className="org-domain-guide"><strong>{uiText("Changes affect future joins only", "変更は今後の参加にのみ適用")}</strong>
      <span>{uiText("Current members and team access stay unchanged.", "現在のメンバーやチーム経由のアクセスは変わりません。")}</span></div>
      {query.data.domains.length === 0 ? <div className="org-domain-empty"><span aria-hidden="true">@</span><div><strong>{uiText("No email domains yet", "メールドメインは未設定です")}</strong>
        <p>{uiText("Add a domain to define how people from your organization can join.", "ドメインを追加して、組織のユーザーが参加する方法を設定できます。")}</p></div></div>
        : <div className="org-domain-list">{query.data.domains.map((row, index) => <article className="org-domain-row" key={row.domain}>
          <span className="org-domain-mark" aria-hidden="true">@</span><div className="org-domain-copy"><strong>{row.domain}</strong><span>{joinPolicyDescription(row.joinPolicy)}</span></div>
          <span className={`org-domain-policy policy-${row.joinPolicy}`}>{joinPolicyLabel(row.joinPolicy)}</span>
          {canManage && <div className="org-domain-actions"><button className="secondary" aria-label={uiText(`Edit ${row.domain}`, `${row.domain} を編集`)} onClick={() => edit(index)}>{uiText("Edit", "編集")}</button>
            <button className="secondary danger-button" aria-label={uiText(`Remove ${row.domain}`, `${row.domain} を削除`)} onClick={() => remove(index)}>{uiText("Remove", "削除")}</button></div>}
        </article>)}</div>}
      <footer className="org-domain-footer"><span>{uiText(`${query.data.domains.length} of 10 domains`, `${query.data.domains.length} / 10 ドメイン`)}</span>
        <span>{uiText("Exact match · shared email services unavailable", "完全一致 · 共有メールサービスは登録不可")}</span></footer></>}
    <DataError error={query.error} retry={query.reload} />
  </section>;
}

function OrganizationJoinRequests({ organizationId }: { organizationId?: string }) {
  const query = useLivePage<components["schemas"]["OrganizationJoinRequest"]>(organizationId ? apiQuery("listOrganizationJoinRequests", { params: { path: { organizationId } } }) : apiQuery("listMyJoinRequests", {}));
  const { dialog, openDialog } = useActionDialog();
  function resolve(requestId: string, action: "approve" | "reject" | "cancel") {
    const label = action === "approve" ? uiText("Approve", "承認") : action === "reject" ? uiText("Reject", "却下") : uiText("Cancel request", "申請を取り消す");
    openDialog({ title: label, confirmLabel: label, onSubmit: async () => {
      const input = { params: { path: { requestId } } };
      if (action === "approve") await api.approveOrganizationJoinRequest(input);
      else if (action === "reject") await api.rejectOrganizationJoinRequest(input);
      else await api.cancelOrganizationJoinRequest(input);
    } });
  }
  const statusLabel = (status: string) => ({ pending: uiText("Pending", "承認待ち"), approved: uiText("Approved", "承認済み"), rejected: uiText("Rejected", "却下"), cancelled: uiText("Cancelled", "取り消し済み") })[status];
  if (!query.data?.items.length && !query.error) return null;
  return <section>{dialog}<h3>{uiText("Join requests", "参加申請")}</h3>
    {query.data?.items.map((request) => <div className="row" key={request.id}><span>{organizationId ? `${request.userName} (${request.userEmail})` : request.organizationName} · {statusLabel(request.status)}</span>{request.status === "pending" && <div>{organizationId ? <><button onClick={() => resolve(request.id, "approve")}>{uiText("Approve", "承認")}</button><button onClick={() => resolve(request.id, "reject")}>{uiText("Reject", "却下")}</button></> : <button onClick={() => resolve(request.id, "cancel")}>{uiText("Cancel request", "申請を取り消す")}</button>}</div>}</div>)}
    {query.data?.nextCursor && <button className="secondary" onClick={query.loadMore}>{uiText("Show more", "さらに表示")}</button>}
    <DataError error={query.error} retry={query.reload} />
  </section>;
}

function OrganizationDetails({ organization, session }: { organization: OrganizationInfo; session: SessionInfo }) {
  const { dialog, openDialog } = useActionDialog();
  const [members, setMembers] = useState<OrganizationMember[]>();
  const [currentRole, setCurrentRole] = useState<string>();
  const [teams, setTeams] = useState<TeamInfo[]>([]);
  const [teamMembers, setTeamMembers] = useState<Record<string, TeamMember[]>>({});
  const [invitations, setInvitations] = useState<OrganizationInvitation[]>();
  const [memberSearch, setMemberSearch] = useState("");
  const [copied, setCopied] = useState(false);
  const [invitationLink, setInvitationLink] = useState<string>();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const organizationId = encodeURIComponent(organization.id);
  const load = useCallback(async () => {
    setError(undefined);
    try {
      const [memberPage, teamItems, activeMember] = await Promise.all([
        json<{ members: OrganizationMember[] }>(`/api/auth/organization/list-members?organizationId=${organizationId}`),
        json<TeamInfo[]>(`/api/auth/organization/list-teams?organizationId=${organizationId}`),
        json<{ role: string }>(`/api/auth/organization/get-active-member-role?organizationId=${organizationId}`),
      ]);
      setMembers(memberPage.members);
      setCurrentRole(activeMember.role);
      const canManageTeams = ["owner", "admin"].includes(activeMember.role);
      const [invitationItems, teamMemberEntries] = await Promise.all([
        canManageTeams
          ? json<OrganizationInvitation[]>(
              `/api/auth/organization/list-invitations?organizationId=${organizationId}`,
            )
          : Promise.resolve([]),
        canManageTeams
          ? Promise.all(memberPage.members.map(async (member) => ({
              member,
              teams: await json<TeamInfo[]>(
                `/api/auth/organization/list-user-teams?userId=${encodeURIComponent(member.userId)}&organizationId=${organizationId}`,
              ),
            }))).then((memberships) => teamItems.map((team): [string, TeamMember[]] => [
              team.id,
              memberships.filter(({ teams }) => teams.some(({ id }) => id === team.id)).map(({ member }) => ({
                id: `${team.id}:${member.userId}`,
                userId: member.userId,
                teamId: team.id,
              })),
            ]))
          : Promise.resolve([] as [string, TeamMember[]][]),
      ]);
      setInvitations(invitationItems.filter((invitation) => invitation.status === "pending"));
      setTeams(teamItems);
      setTeamMembers(Object.fromEntries(teamMemberEntries));
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not load organization");
    }
  }, [organizationId, session.user.id]);
  useEffect(() => { void load(); }, [load]);

  function invite() {
    openDialog({
      title: uiText("Invite member", "メンバーを招待"),
      description: uiText("Create a link and share it with this person. An email is not sent automatically.", "招待リンクを作成して相手に共有します。メールは自動送信されません。"),
      confirmLabel: uiText("Create invitation link", "招待リンクを作成"),
      fields: [{ name: "email", label: uiText("Email address", "メールアドレス"), type: "email", required: true }],
      onSubmit: async ({ email }) => {
        const invitation = await json<OrganizationInvitation>("/api/auth/organization/invite-member", {
          method: "POST", body: JSON.stringify({ email: email!.trim(), role: "member", organizationId: organization.id }),
        });
        setInvitationLink(`${window.location.origin}/accept-invitation/${invitation.id}`);
        setCopied(false);
        await load();
      },
    });
  }

  async function copyInvitation() {
    try {
      await navigator.clipboard.writeText(invitationLink!);
      setCopied(true);
    } catch {
      setError(uiText("Could not copy. Select the link and copy it manually.", "コピーできませんでした。リンクを選択してコピーしてください。"));
    }
  }

  function removeMember(member: OrganizationMember) {
    openDialog({
      title: uiText("Remove member?", "メンバーを削除しますか？"),
      description: uiText(`${member.user.email} will lose access through ${organization.name}.`, `${member.user.email} は「${organization.name}」を通じたアクセスを失います。`),
      confirmLabel: uiText("Remove member", "メンバーを削除"), destructive: true,
      onSubmit: async () => {
        await json("/api/auth/organization/remove-member", { method: "POST", body: JSON.stringify({ memberIdOrEmail: member.id, organizationId: organization.id }) });
        await load();
      },
    });
  }

  async function cancelInvitation(invitation: OrganizationInvitation) {
    if (pending) return;
    setPending(true);
    setError(undefined);
    try {
      await json("/api/auth/organization/cancel-invitation", {
        method: "POST",
        body: JSON.stringify({ invitationId: invitation.id }),
      });
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not cancel invitation");
    } finally {
      setPending(false);
    }
  }

  function renameOrganization() {
    openDialog({ title: uiText("Rename organization", "組織名を変更"), confirmLabel: uiText("Save", "保存"),
      fields: [{ name: "name", label: uiText("Name", "名前"), required: true, value: organization.name }],
      onSubmit: async ({ name }) => { await json("/api/auth/organization/update", { method: "POST", body: JSON.stringify({ organizationId: organization.id, data: { name: name!.trim() } }) }); },
    });
  }

  function changeOrganizationSlug() {
    openDialog({ title: uiText("Change slug", "slug を変更"), confirmLabel: uiText("Save", "保存"),
      description: uiText("Use lowercase letters, numbers, underscores and hyphens. The organization URL will stay the same.", "半角英小文字・数字・アンダーバー・ハイフンを使用してください。変更しても組織の URL は変わりません。"),
      fields: [{ name: "slug", label: "slug", required: true, pattern: organizationSlugPattern.source, value: organization.slug }],
      onSubmit: async ({ slug }) => {
        await json("/api/auth/organization/update", { method: "POST", body: JSON.stringify({ organizationId: organization.id, data: { slug } }) });
      },
    });
  }

  function changeMemberRole(member: OrganizationMember) {
    openDialog({ title: uiText("Change organization role", "組織の権限を変更"), confirmLabel: uiText("Save", "保存"),
      fields: [{ name: "role", label: uiText("Role", "権限"), value: member.role, options: [
        { value: "owner", label: uiText("Owner", "所有者") }, { value: "admin", label: uiText("Admin", "管理者") }, { value: "member", label: uiText("Member", "メンバー") },
      ] }],
      onSubmit: async ({ role }) => { await json("/api/auth/organization/update-member-role", { method: "POST", body: JSON.stringify({ organizationId: organization.id, memberId: member.id, role }) }); await load(); },
    });
  }

  function leaveOrganization() {
    openDialog({ title: uiText("Leave organization?", "組織から脱退しますか？"),
      description: uiText("Access through this organization and its teams will be removed.", "この組織とチームを通じたアクセス権を失います。"),
      confirmLabel: uiText("Leave", "脱退"), destructive: true,
      onSubmit: async () => { await json("/api/auth/organization/leave", { method: "POST", body: JSON.stringify({ organizationId: organization.id }) }); navigateDashboard("/orgs"); },
    });
  }

  function createTeam() {
    openDialog({
      title: uiText("Create team", "チームを作成"),
      description: uiText("Group members to share Workspaces with a team. You can manage members after creating it.", "ワークスペースの共有先となるチームを作成します。作成後にメンバーを設定できます。"),
      confirmLabel: uiText("Create team", "チームを作成"),
      fields: [{ name: "name", label: uiText("Team name", "チーム名"), required: true }],
      onSubmit: async ({ name }) => {
        await json<TeamInfo>("/api/auth/organization/create-team", {
          method: "POST", body: JSON.stringify({ name: name!.trim(), organizationId: organization.id }),
        });
        await load();
      },
    });
  }

  function renameTeam(team: TeamInfo) {
    openDialog({
      title: uiText("Rename team", "チーム名を変更"), confirmLabel: uiText("Save changes", "変更を保存"),
      fields: [{ name: "name", label: uiText("Team name", "チーム名"), hideLabel: true, value: team.name, required: true }],
      onSubmit: async ({ name }) => {
        if (name!.trim() === team.name) return;
        await json("/api/auth/organization/update-team", {
          method: "POST", body: JSON.stringify({ teamId: team.id, data: { name: name!.trim(), organizationId: organization.id } }),
        });
        await load();
      },
    });
  }

  function deleteTeam(team: TeamInfo) {
    openDialog({
      title: uiText("Delete team?", "チームを削除しますか？"),
      description: uiText(`“${team.name}” will be deleted. Members will lose access to Workspaces shared through this team.`, `「${team.name}」を削除し、このチームを通じたワークスペースへのアクセスを解除します。`),
      confirmLabel: uiText("Delete team", "チームを削除"), destructive: true,
      onSubmit: async () => {
        await json("/api/auth/organization/remove-team", {
          method: "POST", body: JSON.stringify({ teamId: team.id, organizationId: organization.id }),
        });
        await load();
      },
    });
  }

  async function setTeamMember(team: TeamInfo, userId: string, enabled: boolean) {
    if (pending) return;
    setPending(true);
    setError(undefined);
    try {
      await json(`/api/auth/organization/${enabled ? "add" : "remove"}-team-member`, {
        method: "POST", body: JSON.stringify({ teamId: team.id, userId, organizationId: organization.id }),
      });
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not update team membership");
    } finally {
      setPending(false);
    }
  }

  const canManage = ["owner", "admin"].includes(currentRole ?? "");
  const teamMemberIds = useMemo(() => Object.fromEntries(
    Object.entries(teamMembers).map(([teamId, entries]) => [teamId, new Set(entries.map(({ userId }) => userId))]),
  ), [teamMembers]);
  const visibleMembers = members?.filter((member) => `${member.user.name} ${member.user.email}`.toLocaleLowerCase().includes(memberSearch.trim().toLocaleLowerCase()));
  return (
    <section className="organization-card">
      {dialog}
      <fieldset className="organization-controls" disabled={pending}>
      <DetailTabs label={uiText("Organization content", "組織の内容")} tabs={[
        ...(canManage ? [{ id: "workspaces", label: uiText("Workspace governance", "ワークスペース管理"), content: <OrganizationWorkspaces organization={organization} /> }] : []),
        { id: "members", label: <>{uiText("Members", "メンバー")}{members && <> <span className="org-count">{members.length}</span></>}</>, content: <>
          <div className="org-section-header flex-row items-center gap-3 max-sm:flex-col max-sm:items-start">
            {members && members.length > 0 && <input className="org-search" type="search" aria-label={uiText("Find members", "メンバーを検索")} placeholder={uiText("Search by name or email", "名前・メールアドレスで検索")} value={memberSearch} onChange={(event) => setMemberSearch(event.target.value)} />}
            {canManage && <button className="primary ml-auto max-sm:ml-0" onClick={invite}><MenuIcon name="plus" />{uiText("Invite member", "メンバーを招待")}</button>}
            {currentRole && <button className="secondary danger-button" onClick={leaveOrganization}>{uiText("Leave", "脱退")}</button>}
          </div>
          {visibleMembers?.length === 0 && <p className="empty-state">{uiText("No matching members.", "該当するメンバーはいません。")}</p>}
          {!members && !error && <p className="muted">{uiText("Loading members…", "メンバーを読み込み中…")}</p>}
          {visibleMembers?.map((member) => (
            <div className="member-row organization-row" key={member.id}>
              <div className="org-person"><span className="org-avatar" aria-hidden="true">{(member.user.name || member.user.email).slice(0, 1).toLocaleUpperCase()}</span><div><strong>{member.user.name || member.user.email}{member.userId === session.user.id && <small className="org-you">{uiText("You", "あなた")}</small>}</strong><span>{member.user.email}</span></div></div>
              <span className="org-role">{member.role === "owner" ? uiText("Owner", "所有者") : member.role === "admin" ? uiText("Administrator", "管理者") : uiText("Member", "メンバー")}</span>
              {canManage && <button className="secondary" onClick={() => changeMemberRole(member)}>{uiText("Change role", "権限を変更")}</button>}
              {canManage && member.userId !== session.user.id && (
                <button className="secondary danger-button" onClick={() => removeMember(member)}>{uiText("Remove", "解除")}</button>
              )}
            </div>
          ))}
          {canManage && (
            <>
              <h3>{uiText("Pending invitations", "承認待ちの招待")}</h3>
              {invitations?.length === 0 && <p className="muted">{uiText("No pending invitations.", "承認待ちの招待はありません。")}</p>}
              {invitations?.map((invitation) => (
                <div className="member-row organization-row" key={invitation.id}>
                  <div><strong>{invitation.email}</strong><span>{uiText("Expires", "有効期限")} {new Date(invitation.expiresAt).toLocaleString()}</span></div>
                  <button className="secondary danger-button" onClick={() => void cancelInvitation(invitation)}>{uiText("Cancel", "キャンセル")}</button>
                </div>
              ))}
              {invitationLink && <div className="org-invitation-result" role="status">
                <strong>{uiText("Invitation link ready", "招待リンクを作成しました")}</strong>
                <p>{uiText("Share this link with the invited person.", "招待した相手にこのリンクを共有してください。")}</p>
                <div className="org-copy-row"><input aria-label={uiText("Invitation link", "招待リンク")} readOnly value={invitationLink} onFocus={(event) => event.target.select()} />
                  <button className="secondary" onClick={() => void copyInvitation()}>{copied ? uiText("Copied", "コピーしました") : uiText("Copy link", "リンクをコピー")}</button></div>
              </div>}
            </>
          )}
        </> },
        { id: "teams", label: <>{uiText("Teams", "チーム")}{invitations && <> <span className="org-count">{teams.length}</span></>}</>, content: <>
          <div className="org-section-header"><div><p>{uiText("Share Workspaces with a smaller group. Open a team to see its members.", "チーム単位でワークスペースを共有できます。チームを開いてメンバーを確認します。")}</p></div>
            {canManage && <button className="primary" onClick={createTeam}><MenuIcon name="plus" />{uiText("Create team", "チームを作成")}</button>}</div>
          {invitations && teams.length === 0 && <div className="empty-state"><strong>{uiText("No teams yet", "チームはまだありません")}</strong><span>{uiText("Create a team for the people you share with regularly.", "よく共有するメンバーをチームにまとめられます。")}</span></div>}
          {teams.map((team) => (
            <details className="team-block" key={team.id}>
              <summary className="org-team-summary"><MenuIcon name="organization" /><strong>{team.name}</strong><span>{teamMembers[team.id] ? uiText(`${teamMembers[team.id]!.length} members`, `${teamMembers[team.id]!.length}名のメンバー`) : uiText("Team", "チーム")}</span></summary>
              <div className="org-team-content"><div className="org-team-toolbar"><p>{canManage ? uiText("Select members. Changes are saved immediately.", "メンバーを選択すると、変更がすぐに保存されます。") : uiText("Team members", "チームのメンバー")}</p>
                {canManage && (
                  <div className="row-actions">
                    <button className="secondary" onClick={() => renameTeam(team)}>{uiText("Rename", "名前を変更")}</button>
                    <button className="secondary danger-button" onClick={() => deleteTeam(team)}>{uiText("Delete", "削除")}</button>
                  </div>
                )}
              </div>
              {canManage && members?.map((member) => (
                <label className="share-row" key={`${team.id}-${member.userId}`}>
                  <span><strong>{member.user.name || member.user.email}</strong><small>{member.user.email}</small></span>
                  <Checkbox
                    disabled={!canManage}
                    checked={teamMemberIds[team.id]?.has(member.userId) === true}
                    onCheckedChange={(checked) => void setTeamMember(team, member.userId, checked === true)}
                  />
                </label>
              ))}
              {!canManage && <p className="muted">{uiText("Ask an organization administrator to manage this team's members.", "メンバーの管理は組織の管理者にお問い合わせください。")}</p>}
              </div>
            </details>
          ))}
        </> },
        { id: "settings", label: uiText("Settings", "設定"), content: <div className="org-settings">
          <section aria-label={uiText("General", "基本情報")}>
            <h3 className="pb-3">{uiText("General", "基本情報")}</h3>
            <dl className="org-settings-fields">
              <div>
                <dt>{uiText("Organization name", "組織名")}</dt>
                <dd><span>{organization.name}</span>{canManage && <button className="secondary" onClick={renameOrganization}>{uiText("Rename", "名前を変更")}</button>}</dd>
              </div>
              <div>
                <dt>slug</dt>
                <dd><code>{organization.slug}</code>{canManage && <button className="secondary" onClick={changeOrganizationSlug}>{uiText("Change slug", "slug を変更")}</button>}</dd>
              </div>
            </dl>
          </section>
          {canManage && <OrganizationJoinRequests organizationId={organization.id} />}
          <OrganizationDomains organizationId={organization.id} canManage={canManage} />
        </div> },
      ]} />
      </fieldset>
      {pending && <p className="muted" role="status">{uiText("Saving changes…", "変更を保存中…")}</p>}
      {error && <div className="org-error" role="alert"><p className="error">{error}</p><button className="secondary" disabled={pending} onClick={() => void load()}>{uiText("Reload", "再読み込み")}</button></div>}
    </section>
  );
}

export function Organization({ session, organizationId }: { session: SessionInfo; organizationId: string }) {
  const query = useLiveJSON<OrganizationInfo[]>("/api/auth/organization/list");
  const organization = query.data?.find((item) => item.id === organizationId);
  return <>
    <nav className="detail-breadcrumbs" aria-label={uiText("Breadcrumbs", "パンくず")}>
      <a className="inline-flex items-center gap-1.5" href="/orgs">{uiText("Your organizations", "所属組織")}</a>
    </nav>
    {organization && <PageHeader title={organization.name} />}
    <DataError error={query.error} retry={query.reload} />
    {!query.data && query.loading && <p role="status">{uiText("Loading organization…", "組織を読み込み中…")}</p>}
    {query.data && !organization && <p role="alert">{uiText("Organization not found or you no longer have access.", "組織が見つからないか、アクセス権がありません。")}</p>}
    {organization && <OrganizationDetails key={organization.id} organization={organization} session={session} />}
  </>;
}

export function Organizations() {
  const candidates = useLivePage<operations["listOrganizationCandidates"]["responses"][200]["content"]["application/json"]["items"][number]>(apiQuery("listOrganizationCandidates", {}));
  const [organizations, setOrganizations] = useState<OrganizationInfo[]>();
  const [invitations, setInvitations] = useState<OrganizationInvitation[]>();
  const { dialog, openDialog } = useActionDialog();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const showCandidates = Boolean(candidates.data?.items.length || candidates.error);
  const load = useCallback(async () => {
    setError(undefined);
    try {
      const [organizationItems, invitationItems] = await Promise.all([
        json<OrganizationInfo[]>("/api/auth/organization/list"), json<OrganizationInvitation[]>("/api/auth/organization/list-user-invitations"),
      ]);
      setOrganizations(organizationItems);
      setInvitations(invitationItems.filter((invitation) => invitation.status === "pending"));
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not load organizations");
    }
  }, []);
  useEffect(() => { void load(); }, [load]);

  async function decide(invitationId: string, accept: boolean) {
    if (pending) return;
    setPending(true);
    setError(undefined);
    try {
      await json(`/api/auth/organization/${accept ? "accept" : "reject"}-invitation`, {
        method: "POST",
        body: JSON.stringify({ invitationId }),
      });
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not update invitation");
    } finally {
      setPending(false);
    }
  }

  return (
    <>
      {dialog}
      <PageHeader title={uiText("Your organizations", "所属組織")} description={uiText("Choose an organization to manage its members and teams.", "組織を選んで、メンバーやチームを管理します。")} />
      {invitations && invitations.length > 0 && (
        <section className="section-block">
          <h2 className="section-label">{uiText("Invitations", "招待")}</h2>
          <div className="panel admin-list">
            {invitations.map((invitation) => (
              <div className="member-row organization-row" key={invitation.id}>
                <div><strong>{invitation.organizationName}</strong><span>{uiText("Expires", "有効期限")} {new Date(invitation.expiresAt).toLocaleString()}</span></div>
                <div className="row-actions">
                  <button className="secondary" disabled={pending} onClick={() => void decide(invitation.id, false)}>{uiText("Decline", "辞退")}</button>
                  <button className="primary" disabled={pending} onClick={() => void decide(invitation.id, true)}>{uiText("Accept", "参加")}</button>
                </div>
              </div>
            ))}
          </div>
        </section>
      )}
      {showCandidates && <section>
        <h2>{uiText("Organizations you can join", "参加できる組織")}</h2>
        {candidates.data?.items.map((candidate) => {
          const autoJoin = candidate.joinPolicy === "auto_join";
          const requestPending = candidate.requestStatus === "pending";
          const actionLabel = autoJoin ? uiText("Join", "参加") : uiText("Apply", "申請");
          function join() {
            openDialog({
              title: candidate.name,
              confirmLabel: actionLabel,
              onSubmit: async () => {
                const input = { params: { path: { organizationId: candidate.id } } };
                if (autoJoin) await api.joinOrganization(input);
                else await api.requestOrganizationJoin(input);
                await load();
              },
            });
          }
          return <div className="row" key={candidate.id}>
            {candidate.logo && <img src={candidate.logo} alt="" width={32} height={32} loading="lazy" referrerPolicy="no-referrer" />}
            <strong>{candidate.name}</strong>
            <span>{joinPolicyLabel(candidate.joinPolicy)}</span>
            <button disabled={requestPending} onClick={join}>{requestPending ? uiText("Pending", "承認待ち") : actionLabel}</button>
          </div>;
        })}
        {candidates.data?.nextCursor && <button className="secondary" onClick={candidates.loadMore}>{uiText("Show more", "さらに表示")}</button>}
        <DataError error={candidates.error} retry={candidates.reload} />
      </section>}
      <OrganizationJoinRequests />
      <section className="section-block organization-list">
        <h2 className="section-label">{uiText("Your organizations", "参加している組織")}</h2>
        {!organizations && !error && <p className="muted">{uiText("Loading organizations…", "組織を読み込み中…")}</p>}
        {organizations?.length === 0 && <div className="panel empty-state"><strong>{uiText("No organizations", "参加している組織はありません")}</strong><span>{uiText("Ask a server administrator to create an organization or invite you.", "サーバー管理者に組織の作成または招待を依頼してください。")}</span></div>}
        <div className="collection-list">{organizations?.map((organization) => (
          <a className="collection-row" href={`/orgs/${encodeURIComponent(organization.id)}`} key={organization.id}>
            <span className="collection-icon"><MenuIcon name="organization" /></span>
            <span className="collection-copy"><strong>{organization.name}</strong><small>{organization.slug}</small></span>
            <MenuIcon name="arrow" />
          </a>
        ))}</div>
      </section>
      {error && <div className="org-error" role="alert"><p className="error">{error}</p><button className="secondary" onClick={() => void load()}>{uiText("Reload", "再読み込み")}</button></div>}
    </>
  );
}

export function Invitation({ invitationId }: { invitationId: string }) {
  const [invitation, setInvitation] = useState<OrganizationInvitation>();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  useEffect(() => {
    void json<OrganizationInvitation>(`/api/auth/organization/get-invitation?id=${encodeURIComponent(invitationId)}`)
      .then(setInvitation)
      .catch((caught: Error) => setError(caught.message));
  }, [invitationId]);

  async function decide(accept: boolean) {
    if (pending) return;
    setPending(true);
    setError(undefined);
    try {
      await json(`/api/auth/organization/${accept ? "accept" : "reject"}-invitation`, {
        method: "POST",
        body: JSON.stringify({ invitationId }),
      });
      navigateDashboard("/orgs");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not update invitation");
    } finally {
      setPending(false);
    }
  }

  return (
    <>
      <PageHeader title={uiText("Organization invitation", "組織への招待")} />
      <section className="panel max-w-[620px] [&>h2]:m-0 [&>h2]:text-base [&>p]:text-[13px] [&>p]:leading-6 [&>p]:text-muted-foreground">
        {!invitation && !error && <p className="muted" role="status">{uiText("Loading invitation…", "招待を読み込み中…")}</p>}
        {invitation && (
          <>
            <h2>{uiText(`Join ${invitation.organizationName}`, `「${invitation.organizationName}」に参加`)}</h2>
            <p>{uiText("Accept to join this organization.", "招待を承認すると、この組織のメンバーになります。")}</p><p className="muted">{uiText("Expires", "有効期限")} {new Date(invitation.expiresAt).toLocaleString()}</p>
            <div className="button-row">
              <button className="secondary" disabled={pending} onClick={() => void decide(false)}>{uiText("Decline", "辞退")}</button>
              <button className="primary" disabled={pending} onClick={() => void decide(true)}>{uiText("Accept invitation", "招待を承認")}</button>
            </div>
          </>
        )}
        {error && <p className="error">{error}</p>}
      </section>
    </>
  );
}
