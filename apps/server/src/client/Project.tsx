import { objectPath } from "../object-url";
import { encodeId } from "../typeid";
import { apiQuery, useLiveJSON, useLivePage } from "./live-data";
import { type Appearance } from "../appearance-model";
import { AppearanceIcon, collectionAppearance, projectAppearance } from "./AppearancePicker";
import { useActionDialog } from "./ActionDialog";
import { useState } from "react";
import { navigateDashboard } from "./navigation";
import { canWriteWorkspace, type SyncedMeetingInfo, type SyncedProjectInfo, type SyncedWorkspaceInfo, syncMessage, uiText } from "./api";
import { DetailTabs } from "./MeetingContent";
import { MenuIcon, useSidebar } from "./Sidebar";
import { Button } from "./components/ui/button";
import { commitSyncTransaction } from "./transactions";
import { meetingCount, MeetingList } from "./Workspaces";
import { BreadcrumbHeader, projectBreadcrumbOptions, workspaceBreadcrumbOptions } from "./Breadcrumbs";
import { DataError } from "./DataError";
import { uuidV7 } from "../id";

export function SyncedProject({ workspaceId, projectId, resolvedProject }: { workspaceId: string; projectId: string; resolvedProject?: SyncedProjectInfo }) {
  const { dialog, openDialog } = useActionDialog();
  const { workspaces } = useSidebar();
  const workspaceQuery = useLiveJSON<SyncedWorkspaceInfo>(apiQuery("getWorkspace", { params: { path: { workspaceId: workspaceId } } }));
  const workspace = workspaceQuery.data;
  const [recovering, setRecovering] = useState(false);
  const projectQuery = useLiveJSON<SyncedProjectInfo>(resolvedProject ? undefined : apiQuery("getProject", { params: { path: { projectId: projectId } } }));
  const project = workspace ? resolvedProject ?? projectQuery.data : undefined;
  const projectsQuery = useLiveJSON<{ items: SyncedProjectInfo[] }>(apiQuery("listProjects", { params: { path: { workspaceId } } }));
  const projects = projectsQuery.data?.items ?? [];
  const parentProject = projects.find((item) => item.projectId === project?.parentProjectId);
  const meetingFilters = { projectId };
  const meetingsQuery = useLivePage<SyncedMeetingInfo>(apiQuery("listMeetings", { params: { path: { workspaceId }, query: meetingFilters } }));
  const meetings = project ? meetingsQuery.data?.items : undefined;
  const projectOptions = projectBreadcrumbOptions(projects, undefined, { projectId, meetings });
  const workspaceOptions = workspaceBreadcrumbOptions(workspaces, workspaceId, projectOptions);
  const nextCursor = meetingsQuery.data?.nextCursor;
  const loadingMore = meetingsQuery.loadingMore;
  const editProject = () => {
    if (!project) return;
    openDialog({
      title: uiText("Edit Project", "プロジェクトを編集"), confirmLabel: uiText("Save changes", "変更を保存"),
      fields: [
        { name: "name", label: uiText("Project name", "プロジェクト名"), value: project.name, required: true },
        { name: "description", label: uiText("Description", "説明"), value: project.description, multiline: true },
        { name: "appearance", label: uiText("Appearance", "見た目"), appearance: project.parentProjectId ? "inherited" : "editable", value: JSON.stringify(projectAppearance(project, parentProject)) },
      ],
      onSubmit: async ({ name, description, appearance }) => {
        await commitSyncTransaction(workspaceId, [{ entity: "project", action: "update", entityId: projectId, baseRevision: project.revision,
          data: { ...(!project.parentProjectId ? JSON.parse(appearance!) as Appearance : {}), parentProjectId: project.parentProjectId ?? null, name: name!.trim(), description: description ?? "",
            projectType: project.parentProjectId ? null : project.projectType ?? "undefined" } }], setRecovering);
      },
    });
  };
  const createSubproject = () => {
    if (!project || project.parentProjectId) return;
    openDialog({
      title: uiText("New Subproject", "サブプロジェクトを作成"), confirmLabel: uiText("Create Subproject", "サブプロジェクトを作成"),
      description: uiText(`Create a Subproject in “${project.name}”.`, `「${project.name}」内にサブプロジェクトを作成します。`),
      fields: [
        { name: "name", label: uiText("Subproject name", "サブプロジェクト名"), required: true },
        { name: "description", label: uiText("Description", "説明"), multiline: true },
      ],
      onSubmit: async ({ name, description }) => {
        const id = encodeId("project", uuidV7());
        await commitSyncTransaction(workspaceId, [{ entity: "project", action: "create", entityId: id, baseRevision: null,
          data: { parentProjectId: projectId, name: name!.trim(), description: description ?? "", projectType: null, createdAt: new Date().toISOString() } }], setRecovering);
        navigateDashboard(objectPath(id));
      },
    });
  };
  const deleteProject = () => {
    if (!project) return;
    openDialog({
      title: uiText("Delete Project?", "プロジェクトを削除しますか？"),
      description: uiText(`“${project.path}” will be permanently deleted. Only empty projects can be deleted.`, `「${project.path}」を完全に削除します。削除できるのは空のプロジェクトのみです。`),
      confirmLabel: uiText("Delete Project", "プロジェクトを削除"), destructive: true,
      onSubmit: async () => {
        await commitSyncTransaction(workspaceId, [{ entity: "project", action: "delete", entityId: projectId,
          baseRevision: project.revision, data: {} }], setRecovering);
        navigateDashboard(objectPath(workspaceId));
      },
    });
  };
  return <article className="main-column meeting-detail collection-detail">
    {project && <BreadcrumbHeader segments={[
        { href: objectPath(workspaceId), label: workspace?.name ?? uiText("Workspace", "ワークスペース"),
          icon: <AppearanceIcon appearance={collectionAppearance(workspace, "workspace")} />,
          menuLabel: uiText("Workspaces", "ワークスペース"), options: workspaceOptions },
        ...(parentProject ? [{ href: objectPath(parentProject.projectId), label: parentProject.name,
          icon: <AppearanceIcon appearance={projectAppearance(parentProject)} />,
          menuLabel: uiText("Projects", "プロジェクト"), options: projectOptions }] : []),
        { current: true, label: project.name, icon: <AppearanceIcon appearance={projectAppearance(project, parentProject)} />,
          menuLabel: parentProject ? uiText(`Projects in ${parentProject.name}`, `${parentProject.name} 内のプロジェクト`) : uiText("Projects", "プロジェクト"),
          options: projectBreadcrumbOptions(projects, project.parentProjectId ?? undefined, { projectId, meetings }) },
      ]} />}
    <header className="meeting-header">
      <h1><AppearanceIcon appearance={projectAppearance(project, parentProject)} size={28} />{project?.name ?? uiText("Project", "プロジェクト")}</h1>
      {project?.description && <p className="project-description">{project.description}</p>}
      {project && <div className="meeting-metadata"><span className="metadata-chip">{meetingCount(project.subtreeMeetingCount ?? 0)}</span></div>}
    </header>
    {dialog}
    {recovering && <p role="status">{syncMessage("sync_recovering")}</p>}
    <DataError error={workspaceQuery.error} retry={workspaceQuery.reload} />
    <DataError error={projectQuery.error} retry={projectQuery.reload} />
    <DataError error={projectsQuery.error} retry={projectsQuery.reload} />
    <DetailTabs label={uiText("Project content", "プロジェクトの内容")}
      actions={project && !project.parentProjectId && canWriteWorkspace(workspace?.role)
        ? <Button variant="outline" size="sm" onClick={createSubproject}><MenuIcon name="plus" />{uiText("New Subproject", "サブプロジェクトを作成")}</Button>
        : undefined}
      tabs={[
      { id: "meetings", label: uiText("Meetings", "ミーティング"), content: <>
        <DataError error={meetingsQuery.error} retry={meetingsQuery.reload} />
        <MeetingList meetings={meetings} loading={meetingsQuery.loading} />
        {nextCursor && <button className="secondary load-more" disabled={loadingMore} onClick={meetingsQuery.loadMore}>{loadingMore ? uiText("Loading…", "読み込み中…") : uiText("Load more", "さらに表示")}</button>}
      </> },
      { id: "settings", label: uiText("Settings", "設定"), content: <>
        <section className="workspace-settings">
          <h2>{uiText("Project details", "プロジェクトの詳細")}</h2>
          <div className="collection-heading"><span>{project?.name}</span>
            {project && canWriteWorkspace(workspace?.role) && <button className="secondary" onClick={editProject}>{uiText("Edit Project", "プロジェクトを編集")}</button>}
          </div>
        </section>
        {project && canWriteWorkspace(workspace?.role) && <section className="workspace-settings">
          <h2>{uiText("Delete Project", "プロジェクトを削除")}</h2>
          <div className="collection-heading">
            <p>{uiText("Only empty projects can be deleted.", "削除できるのは空のプロジェクトのみです。")}</p>
            <button className="secondary danger-button" onClick={deleteProject}>{uiText("Delete Project", "プロジェクトを削除")}</button>
          </div>
        </section>}
      </> },
    ]} />
  </article>;
}
