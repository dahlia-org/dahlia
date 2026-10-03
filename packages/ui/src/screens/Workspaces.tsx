import { objectPath } from "../model/object-url";
import { WorkspaceMemory } from "./WorkspaceMemory";
import { WorkspaceSharing } from "./WorkspaceSharing";
import { encodeId } from "../model/typeid";
import { apiOperations as api } from "../api/generated-operations";
import { type components } from "../api/generated-api";
import { apiQuery, useLiveJSON, useLivePage } from "../api/live-data";
import { Select } from "../components/Select";
import { type Appearance } from "../model/appearance";
import { AppearanceIcon, collectionAppearance, projectAppearance } from "./AppearancePicker";
import { type DialogField, useActionDialog } from "./ActionDialog";
import { ServerSummarySettings } from "./SummaryGeneration";
import { RecordingIndicator } from "./RecordingIndicator";
import { useEffect, useState } from "react";
import { navigateDashboard } from "../app/navigation";
import { canWriteWorkspace, type SyncedMeetingInfo, type SyncedProjectInfo, type SyncedWorkspaceInfo, syncMessage, uiText, workspaceRoleLabel } from "../api/api";
import { DetailTabs } from "./MeetingContent";
import { MenuIcon, useSidebar } from "./Sidebar";
import { PageHeader } from "../layout/AppShell";
import { type SessionInfo } from "../app/dashboard";
import { commitSyncTransaction, createWorkspaceRecord } from "../api/transactions";
import { BreadcrumbHeader, projectBreadcrumbOptions, workspaceBreadcrumbOptions } from "./Breadcrumbs";
import { DataError } from "./DataError";
import { uuidV7 } from "../model/id";

export function workspaceEncryptionFields(enabled: boolean): DialogField[] {
  return enabled ? [{ name: "encryption", label: uiText("Database encryption", "DB 内データの暗号化"), value: "none", options: [
    { value: "none", label: uiText("None", "暗号化しない") },
    { value: "server", label: uiText("Server encryption (excluding search)", "Server 暗号化（検索データを除く）") },
  ] }] : [];
}
export function Overview({ session }: { session: SessionInfo }) {
  if (session.capabilities.sync) return <Workspaces />;
  return (
    <>
      <PageHeader title="Overview" />
      <section className="section-block">
        <h2 className="section-label">Account</h2>
        <div className="panel account-card">
          <dl className="account-details">
            <div><dt>Name</dt><dd>{session.user.name || "—"}</dd></div>
            <div><dt>Email address</dt><dd>{session.user.email || "—"}</dd></div>
            <div><dt>Account</dt><dd>Personal account</dd></div>
          </dl>
        </div>
      </section>
    </>
  );
}
export function Workspaces() {
  const { dialog, openDialog } = useActionDialog();
  const { workspaces, error: loadError, reload, organizations } = useSidebar();
  const availableOrganizations = organizations ?? [];
  const [recentWorkspaceId, setRecentWorkspaceId] = useState("");
  const recentWorkspace = workspaces?.find((workspace) => workspace.workspaceId === recentWorkspaceId) ?? workspaces?.[0];
  useEffect(() => {
    if (recentWorkspace) setRecentWorkspaceId(recentWorkspace.workspaceId);
  }, [recentWorkspace]);
  const recent = useLiveJSON<{ items: SyncedMeetingInfo[] }>(recentWorkspace ? apiQuery("listMeetings", { params: { path: { workspaceId: recentWorkspace.workspaceId } } }) : undefined);
  const [recovering, setRecovering] = useState(false);

  const { data: encryptionCapabilities } = useLiveJSON<{ workspaceEncryption?: { version: number } }>(apiQuery("getCapabilities", {}));
  const createWorkspace = () => openDialog({
    title: uiText("New Workspace", "ワークスペースを作成"),
    description: uiText("Choose the Organization that will own this Workspace. Sharing is configured after creation.", "ワークスペースを所有する組織を選んでください。共有は作成後に設定できます。"),
    confirmLabel: uiText("Create Workspace", "ワークスペースを作成"),
    fields: [{ name: "name", label: uiText("Workspace name", "ワークスペース名"), required: true },
      { name: "organizationId", label: uiText("Organization", "組織"), required: true,
      value: availableOrganizations[0]?.id,
      options: availableOrganizations.map((organization) => ({ value: organization.id, label: organization.name })) },
      ...workspaceEncryptionFields(Boolean(encryptionCapabilities?.workspaceEncryption))],
    onSubmit: async ({ name, encryption, organizationId: targetOrganizationId }) => {
      const id = await createWorkspaceRecord(targetOrganizationId!, name!, encryption, setRecovering);
      navigateDashboard(objectPath(id));
    },
  });
  return <>
    {dialog}
    <PageHeader title={uiText("Home", "ホーム")}
      description={uiText("Pick up where your last conversation left off.", "前回の会話の続きから、始めましょう。")}
      actions={<button className="primary" disabled={availableOrganizations.length === 0} onClick={createWorkspace}><MenuIcon name="plus" />{uiText("New Workspace", "ワークスペースを作成")}</button>} />
    {recovering && <p role="status">{syncMessage("sync_recovering")}</p>}
    <section className="section-block">
      <div className="collection-heading"><h2>{uiText("Your Workspaces", "ワークスペース一覧")}</h2>{workspaces && <span className="muted">{workspaces.length}</span>}</div>
      {!workspaces && !loadError && <p className="content-empty" role="status">{uiText("Loading Workspaces…", "ワークスペースを読み込み中…")}</p>}
      {loadError && <p className="error" role="alert">{loadError} <button className="secondary" onClick={reload}>{uiText("Retry", "再試行")}</button></p>}
      {workspaces?.length === 0 && <div className="welcome-empty">
        <span className="empty-symbol"><MenuIcon name="workspace" /></span>
        <h2>{uiText("A home for your meetings", "ミーティングの記録を、ひとつの場所に")}</h2>
        <p>{uiText("Create a Workspace, then connect it in Dahlia for macOS to bring your meeting notes, transcripts and screenshots here.", "ワークスペースを作成して macOS 版 Dahlia で接続すると、ミーティングの要約・文字起こし・スクリーンショットをここで閲覧できます。")}</p>
      </div>}
      <div className="workspace-grid">{workspaces?.map((workspace) => <a className="workspace-card" href={objectPath(workspace.workspaceId)} key={workspace.workspaceId}>
          <div className="workspace-card-top"><span className="workspace-symbol"><AppearanceIcon appearance={collectionAppearance(workspace, "workspace")} size={22} /></span><span className={`inline-block rounded-full px-2 py-1 text-[11px] font-bold capitalize ${workspace.role === "admin" ? "bg-muted text-muted-foreground" : "bg-accent text-primary"}`}>{workspaceRoleLabel(workspace.role)}</span></div>
          <h3>{workspace.name}</h3>
          <span className="workspace-organization-badge" role="img" aria-label={uiText(`Organization: ${workspace.organizationName}`, `組織: ${workspace.organizationName}`)} title={workspace.organizationName}><MenuIcon name="organization" /><span>{workspace.organizationName}</span></span>
          <div className="workspace-card-bottom"><span>{uiText("Updated", "更新日")} {new Date(workspace.updatedAt ?? workspace.createdAt).toLocaleDateString()}</span><MenuIcon name="arrow" /></div>
        </a>)}</div>
    </section>
    {recentWorkspace && <section className="section-block recent-meetings">
      <div className="collection-heading"><h2>{uiText("Recent meetings", "最近のミーティング")}</h2>
        <Select aria-label={uiText("Workspace for recent meetings", "最近のミーティングのワークスペース")} value={recentWorkspace.workspaceId} onValueChange={(value) => setRecentWorkspaceId(value)}>
          {workspaces?.map((workspace) => <option value={workspace.workspaceId} key={workspace.workspaceId}><AppearanceIcon appearance={collectionAppearance(workspace, "workspace")} /><span>{workspace.name}</span></option>)}
        </Select>
      </div>
      <DataError error={recent.error} retry={recent.reload} />
      <MeetingList meetings={recent.data?.items.slice(0, 10)} loading={recent.loading} />
      <a className="inline-flex items-center gap-2 py-3 text-[13px] font-medium text-primary hover:underline" href={objectPath(recentWorkspace.workspaceId)}>{uiText("View all meetings", "すべてのミーティングを見る")} <MenuIcon name="arrow" /></a>
    </section>}
  </>;
}


function WorkspaceTransfer({ workspace }: { workspace: SyncedWorkspaceInfo }) {
  const { dialog, openDialog } = useActionDialog();
  const targets = useLiveJSON<{ items: SyncedWorkspaceInfo[] }>(apiQuery("listWorkspaces", {}));
  const [destinationId, setDestinationId] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string>();
  const available = targets.data?.items.filter((item) => item.role === "admin" && item.workspaceId !== workspace.workspaceId) ?? [];
  const destination = available.find((item) => item.workspaceId === destinationId);
  async function confirm() {
    if (!destination || loading) return;
    setLoading(true);
    setError(undefined);
    try {
      const [source, target, audience] = await Promise.all([
        api.getWorkspace({ params: { path: { workspaceId: workspace.workspaceId } } }),
        api.getWorkspace({ params: { path: { workspaceId: destination.workspaceId } } }),
        api.getTransferAudience({ params: { path: { workspaceId: workspace.workspaceId }, query: { destinationWorkspaceId: destination.workspaceId } } }),
      ]);
      const people = (items: { name: string; email: string }[]) => items.map((person) => `${person.name} (${person.email})`).join(", ");
      const description = [
        uiText(`Move all Server-saved content from “${source.name}” to “${target.name}”. The source Workspace will remain empty.`,
          `「${source.name}」のServer保存済みの全内容を「${target.name}」へ移管します。元のワークスペースは空で残ります。`),
        audience.removed.length ? uiText(`Will lose access: ${people(audience.removed)}.`, `閲覧できなくなる人：${people(audience.removed)}。`) : "",
        audience.added.length ? uiText(`Will gain access: ${people(audience.added)}.`, `新しく閲覧できる人：${people(audience.added)}。`) : "",
        !audience.removed.length && !audience.added.length ? uiText("No change to the current readers.", "現在の閲覧者に変更はありません。") : "",
        uiText("Devices without access will pause sync and keep local data. Unsynced data is not transferred.",
          "移管先を閲覧できない端末はローカルデータを保持して同期を停止します。未同期データは移管されません。"),
      ].filter(Boolean).join("\n\n");
      const key = encodeId("transaction", uuidV7());
      const body = { destinationWorkspaceId: target.workspaceId, sourceRevision: source.revision, destinationRevision: target.revision, audienceHash: audience.audienceHash };
      openDialog({ title: uiText("Transfer content", "内容を移管"), description,
        confirmLabel: uiText("Transfer", "移管する"), destructive: true,
        onSubmit: async () => {
          await api.transferWorkspace({ params: { path: { workspaceId: source.workspaceId }, header: { "idempotency-key": key } }, body });
          window.location.assign(objectPath(target.workspaceId));
        },
      });
    } catch (caught) { setError(caught instanceof Error ? caught.message : String(caught)); }
    finally { setLoading(false); }
  }
  return <section className="workspace-settings"><h2>{uiText("Transfer content", "内容を移管")}</h2>
    <p>{uiText("Move all saved content to another Workspace you administer.", "保存済みの全内容を、管理権限のある別のワークスペースへ移します。")}</p>
    <div className="collection-heading"><Select aria-label={uiText("Destination Workspace", "移管先のワークスペース")} placeholder={uiText("Choose a Workspace", "ワークスペースを選択")} menuLabel={uiText("Workspaces", "ワークスペース")} value={destinationId} disabled={loading}
      onValueChange={(value) => setDestinationId(value)}>
      {available.map((item) => <option key={item.workspaceId} value={item.workspaceId}><AppearanceIcon appearance={collectionAppearance(item, "workspace")} /><span>{item.name}</span></option>)}
    </Select><button className="secondary" disabled={!destination || loading || workspace.hasResources !== true} onClick={() => void confirm()}>
      {loading ? uiText("Checking…", "確認中…") : uiText("Transfer content", "内容を移管")}</button></div>
    {targets.data && !available.length && <p className="muted">{uiText("Create another Workspace to transfer content.", "移管先となる別のワークスペースを作成してください。")}</p>}
    <DataError error={targets.error} retry={targets.reload} />{error && <p className="error" role="alert">{error}</p>}{dialog}
  </section>;
}

export function meetingCount(count: number) { return uiText(`${count} meeting${count === 1 ? "" : "s"}`, `${count}件のミーティング`); }

export function MeetingList({ meetings, loading, filtered = false, onClear }: { meetings?: SyncedMeetingInfo[]; loading: boolean; filtered?: boolean; onClear?: () => void }) {
  return <div className="collection-list" aria-busy={loading}>
    {!meetings && loading && <p className="content-empty" role="status">{uiText("Loading meetings…", "ミーティングを読み込み中…")}</p>}
    {meetings?.length === 0 && <div className="welcome-empty border-0 bg-transparent px-5 py-10">
      <span className="empty-symbol"><MenuIcon name={filtered ? "search" : "document"} /></span>
      <h2>{filtered ? uiText("No matching meetings", "条件に一致するミーティングがありません") : uiText("No meetings yet", "ミーティングはまだありません")}</h2>
      <p>{filtered ? uiText("Try a different title or clear your filters.", "別のタイトルで検索するか、絞り込みを解除してください。") : uiText("Meetings synced from Dahlia for macOS will appear here.", "macOS 版 Dahlia から同期されたミーティングがここに表示されます。")}</p>
      {filtered && onClear && <button className="secondary" onClick={onClear}>{uiText("Clear filters", "絞り込みを解除")}</button>}
    </div>}
    {meetings?.map((meeting) => {
      const date = meeting.recordingStartedAt ?? meeting.createdAt;
      return <a className="collection-row meeting-list-row" href={objectPath(meeting.meetingId)} key={meeting.meetingId}>
        <span className="collection-icon"><MenuIcon name="document" /></span>
        <span className="collection-copy"><strong>{meeting.name || uiText("Untitled meeting", "無題のミーティング")} <RecordingIndicator isRecording={meeting.isRecording} /></strong>
          <span className="collection-date"><time dateTime={date}>{new Date(date).toLocaleString(undefined, { year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}</time>
          {meeting.duration != null && <span> · {Math.floor(meeting.duration / 60)}:{String(Math.floor(meeting.duration % 60)).padStart(2, "0")}</span>}</span>
        </span>
        <MenuIcon name="arrow" />
      </a>;
    })}
  </div>;
}

export function WorkspaceTrash({ workspace }: { workspace: SyncedWorkspaceInfo }) {
  const query = useLivePage(apiQuery("listDeletedMeetings", { params: { path: { workspaceId: workspace.workspaceId } } }));
  const [pending, setPending] = useState<string>();
  const [error, setError] = useState<string>();
  const [restored, setRestored] = useState<string>();
  const [recovering, setRecovering] = useState(false);
  async function restore(meeting: components["schemas"]["DeletedMeeting"]) {
    if (pending) return;
    setPending(meeting.meetingId);
    setError(undefined);
    setRestored(undefined);
    try {
      await commitSyncTransaction(workspace.workspaceId, [{ entity: "meeting", action: "restore", entityId: meeting.meetingId, baseRevision: meeting.revision, data: {} }], setRecovering);
      setRestored(meeting.name);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : uiText("Could not restore the meeting.", "ミーティングを復旧できませんでした。"));
      query.reload();
    } finally { setPending(undefined); }
  }
  return <section aria-label={uiText("Deleted meetings", "削除済みミーティング")}>
    <p className="muted">{uiText(`Meetings are permanently deleted after ${workspace.meetingDeletionGraceDays} days. They can be restored until cleanup runs.`, `ミーティングは削除から${workspace.meetingDeletionGraceDays}日後に完全削除の対象となります。削除処理が完了するまでは復旧できます。`)}</p>
    <DataError error={query.error} retry={query.reload} />
    {error && <p role="alert" className="dialog-error">{error}</p>}
    <p role="status">{recovering ? syncMessage("sync_recovering") : restored ? uiText(`Restored “${restored}”.`, `「${restored}」を復旧しました。`) : ""}</p>
    {query.loading && !query.data && <p className="content-empty">{uiText("Loading…", "読み込み中…")}</p>}
    {query.data?.items.length === 0 && <p className="content-empty">{uiText("Trash is empty", "ごみ箱は空です")}</p>}
    <div className="collection-list">{query.data?.items.map((meeting) => {
      const scheduled = new Date(new Date(meeting.deletedAt).getTime() + workspace.meetingDeletionGraceDays * 86_400_000);
      return <div className="collection-heading" key={meeting.meetingId}>
        <div><strong>{meeting.name || uiText("Untitled meeting", "無題のミーティング")}</strong>
          <p className="muted">{uiText("Deleted: ", "削除日時：")}<time dateTime={meeting.deletedAt}>{new Date(meeting.deletedAt).toLocaleString()}</time>{" · "}
            {scheduled.getTime() <= Date.now() ? uiText("Awaiting deletion", "削除待ち") : <>{uiText("Scheduled for deletion: ", "削除予定：")}<time dateTime={scheduled.toISOString()}>{scheduled.toLocaleString()}</time></>}</p>
        </div>
        {canWriteWorkspace(workspace.role) && <button className="secondary" disabled={pending !== undefined} onClick={() => void restore(meeting)}>{pending === meeting.meetingId ? uiText("Restoring…", "復旧中…") : uiText("Restore", "復旧")}</button>}
      </div>;
    })}</div>
    {query.data?.nextCursor && <button className="secondary load-more" disabled={query.loadingMore} onClick={query.loadMore}>{query.loadingMore ? uiText("Loading…", "読み込み中…") : uiText("Load more", "さらに表示")}</button>}
  </section>;
}

export function WorkspaceMeetings({ session, workspaceId, serverAI = true }: { session: SessionInfo; workspaceId: string; serverAI?: boolean }) {
  const { dialog, openDialog } = useActionDialog();
  const { workspaces } = useSidebar();
  const workspaceQuery = useLiveJSON<SyncedWorkspaceInfo>(apiQuery("getWorkspace", { params: { path: { workspaceId: workspaceId } } }));
  const workspace = workspaceQuery.data;
  const personal = workspace?.personalUserId != null;
  const [recovering, setRecovering] = useState(false);
  const projectsQuery = useLiveJSON<{ items: SyncedProjectInfo[] }>(apiQuery("listProjects", { params: { path: { workspaceId: workspaceId } } }));
  const projects = workspace ? projectsQuery.data?.items ?? [] : [];
  const workspaceOptions = workspaceBreadcrumbOptions(workspaces, workspaceId, projectBreadcrumbOptions(projects));
  const [query, setQuery] = useState("");
  const [projectId, setProjectId] = useState("");
  useEffect(() => {
    if (projectsQuery.data && !projectsQuery.data.items.some((project) => project.projectId === projectId)) setProjectId("");
  }, [projectId, projectsQuery.data]);
  const [search, setSearch] = useState("");
  useEffect(() => {
    const timer = setTimeout(() => setSearch(query), 250);
    return () => clearTimeout(timer);
  }, [query]);
  const meetingFilters = { query: search || undefined, projectId: projectId || undefined };
  const meetingsQuery = useLivePage<SyncedMeetingInfo>(apiQuery("listMeetings", { params: { path: { workspaceId }, query: meetingFilters } }));
  const meetings = workspace ? meetingsQuery.data?.items : undefined;
  const nextCursor = meetingsQuery.data?.nextCursor;
  const loadingMore = meetingsQuery.loadingMore;
  const renameWorkspace = () => {
    if (!workspace) return;
    openDialog({
      title: uiText("Edit Workspace", "ワークスペースを編集"), confirmLabel: uiText("Save changes", "変更を保存"),
      description: uiText("The deletion grace period also applies to meetings already in the trash. Shortening it may delete them at the next cleanup.", "削除の猶予期間は、ごみ箱内のミーティングにも適用されます。短縮すると、次の削除処理で完全に削除される場合があります。"),
      fields: [{ name: "name", label: uiText("Workspace name", "ワークスペース名"), value: workspace.name, required: true },
        { name: "appearance", label: uiText("Appearance", "見た目"), appearance: "editable", value: JSON.stringify(collectionAppearance(workspace, "workspace")) },
        { name: "meetingDeletionGraceDays", label: uiText("Deletion grace period (days)", "削除の猶予期間（日）"), type: "number", min: 1, max: 90, required: true, value: String(workspace.meetingDeletionGraceDays) }],
      onSubmit: async ({ name, appearance, meetingDeletionGraceDays }) => {
        await commitSyncTransaction(workspaceId, [{ entity: "workspace", action: "update", entityId: workspaceId,
          baseRevision: workspace.revision, data: { meetingDeletionGraceDays: Number(meetingDeletionGraceDays), name: name!.trim(), ...(JSON.parse(appearance!) as Appearance) } }], setRecovering);
      },
    });
  };
  const deleteWorkspace = () => {
    if (!workspace || workspace.role !== "admin") return;
    openDialog({
      title: uiText("Delete Workspace?", "ワークスペースを削除しますか？"),
      description: uiText(`Delete the empty Workspace “${workspace.name}”? This cannot be undone.`, `空のワークスペース「${workspace.name}」を削除します。この操作は取り消せません。`),
      confirmLabel: uiText("Delete Workspace", "ワークスペースを削除"), destructive: true,
      onSubmit: async () => {
        await commitSyncTransaction(workspaceId, [{ entity: "workspace", action: "reset", entityId: workspaceId,
          baseRevision: workspace.revision, data: { preservePermissions: false } }], setRecovering);
        navigateDashboard("/dashboard");
      },
    });
  };
  const createProject = () => openDialog({
    title: uiText("New Project", "プロジェクトを作成"),
    description: uiText(`Organize meetings in ${workspace?.name ?? "this Workspace"}.`, `「${workspace?.name ?? "このワークスペース"}」のミーティングを整理します。`),
    confirmLabel: uiText("Create Project", "プロジェクトを作成"),
    fields: [
      { name: "name", label: uiText("Project name", "プロジェクト名"), required: true },
      { name: "description", label: uiText("Description", "説明"), multiline: true },
    ],
    onSubmit: async ({ name, description }) => {
      const id = encodeId("project", uuidV7());
      await commitSyncTransaction(workspaceId, [{ entity: "project", action: "create", entityId: id, baseRevision: null,
        data: { parentProjectId: null, name: name!.trim(), description: description ?? "", projectType: "undefined", createdAt: new Date().toISOString() } }], setRecovering);
      navigateDashboard(objectPath(id));
    },
  });
  return <article className="main-column meeting-detail collection-detail" aria-busy={!workspace && workspaceQuery.loading}>
    {workspace && <>
      <BreadcrumbHeader segments={[{ current: true, label: workspace.name,
        icon: <AppearanceIcon appearance={collectionAppearance(workspace, "workspace")} />,
        menuLabel: uiText("Workspaces", "ワークスペース"), options: workspaceOptions }]} />
      <header className="meeting-header"><h1><AppearanceIcon appearance={collectionAppearance(workspace, "workspace")} size={28} />{workspace.name}</h1>
      <div className="meeting-metadata"><span className="metadata-chip">{workspaceRoleLabel(workspace.role)}</span></div>
    </header></>}
    {dialog}
    {recovering && <p role="status">{syncMessage("sync_recovering")}</p>}
    <DataError error={workspaceQuery.error} retry={workspaceQuery.reload} />
    {!workspace && workspaceQuery.loading && <p role="status">{uiText("Loading Workspace…", "ワークスペースを読み込み中…")}</p>}
    {workspace && <DetailTabs label={uiText("Workspace content", "ワークスペースの内容")} tabs={[
      { id: "meetings", label: uiText("Meetings", "ミーティング"), content: <>
        <div className="collection-filters">
          <input type="search" className="model-search" aria-label={uiText("Search meetings", "ミーティングを検索")} placeholder={uiText("Search meetings", "ミーティングを検索")} value={query} onChange={(event) => setQuery(event.target.value)} />
          {projects.length > 0 && <Select aria-label={uiText("Filter by Project", "プロジェクトで絞り込み")} value={projectId} onValueChange={(value) => setProjectId(value)}>
            <option value="">{uiText("All Projects", "すべてのプロジェクト")}</option>
            {projects.map((project) => <option key={project.projectId} value={project.projectId}>{project.path}</option>)}
          </Select>}
        </div>
        <DataError error={projectsQuery.error} retry={projectsQuery.reload} />
        <DataError error={meetingsQuery.error} retry={meetingsQuery.reload} />
        <MeetingList meetings={meetings} loading={meetingsQuery.loading} filtered={Boolean(query || projectId)} onClear={() => { setQuery(""); setSearch(""); setProjectId(""); }} />
        {nextCursor && <button className="secondary load-more" disabled={loadingMore} onClick={meetingsQuery.loadMore}>{loadingMore ? uiText("Loading…", "読み込み中…") : uiText("Load more", "さらに表示")}</button>}
      </> },
      { id: "projects", label: uiText("Projects", "プロジェクト"), content: <>
        <div className="collection-heading"><h2>{uiText("Projects", "プロジェクト")}</h2>{canWriteWorkspace(workspace?.role) && <button className="secondary" onClick={createProject}>{uiText("New Project", "プロジェクトを作成")}</button>}</div>
        <DataError error={projectsQuery.error} retry={projectsQuery.reload} />
        {projectsQuery.loading && !projectsQuery.data && <p className="content-empty">{uiText("Loading…", "読み込み中…")}</p>}
        {projectsQuery.data && projects.length === 0 && <p className="content-empty">{uiText("No projects yet", "プロジェクトはまだありません")}</p>}
        <div className="collection-list">{projects.map((project) => <a className="collection-row project-list-row" href={objectPath(project.projectId)} key={project.projectId}>
          <span className="collection-project-name"><AppearanceIcon appearance={projectAppearance(project, projects.find((parent) => parent.projectId === project.parentProjectId))} /><strong>{project.path}</strong></span><span className="muted">{meetingCount(project.subtreeMeetingCount ?? 0)}</span>
        </a>)}</div>
      </> },
      ...(workspace ? [{ id: "trash", label: uiText("Trash", "ごみ箱"), content: <WorkspaceTrash workspace={workspace} /> }] : []),
      ...(session.capabilities.sharing && workspace ? [{ id: "permissions", label: uiText("Permissions", "権限"), content: <WorkspaceSharing workspace={workspace} /> }] : []),
      { id: "settings", label: uiText("Settings", "設定"), content: <>
        <section className="workspace-settings"><h2>{uiText("Workspace details", "ワークスペースの詳細")}</h2><div className="collection-heading"><span>{workspace?.name}</span>{workspace?.role === "admin" && <button className="secondary" onClick={renameWorkspace}>{uiText("Edit Workspace", "ワークスペースを編集")}</button>}</div></section>
        {serverAI && workspace && <ServerSummarySettings key={`generation-${workspaceId}`} workspaceId={workspaceId} onSave={(current, generationSettings) =>
          commitSyncTransaction(workspaceId, [{ entity: "workspace", action: "update", entityId: workspaceId,
            baseRevision: current.revision, data: { name: current.name, generationSettings } }], setRecovering)} />}
        {workspace && <WorkspaceMemory key={`memory-${workspaceId}`} workspaceId={workspaceId} role={workspace.role} />}
        {workspace?.role === "admin" && <WorkspaceTransfer workspace={workspace} />}
        {workspace?.role === "admin" && !personal && <section className="workspace-settings"><h2>{uiText("Delete Workspace", "ワークスペースを削除")}</h2>
          <div className="collection-heading"><p>{uiText("Only empty Workspaces can be deleted. Transfer resources or wait for meetings in the trash to be permanently deleted.", "空のワークスペースのみ削除できます。ごみ箱内のミーティングを含むリソースが残っている場合は、先に移管または削除完了を待ってください。")}</p>
          <button className="secondary danger-button" disabled={workspace.hasResources !== false} onClick={deleteWorkspace}>{uiText("Delete Workspace", "ワークスペースを削除")}</button></div>
        </section>}
      </> },
    ]} />}
  </article>;
}
