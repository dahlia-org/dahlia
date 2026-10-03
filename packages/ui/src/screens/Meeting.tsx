import { objectPath } from "../model/object-url";
import { MeetingNotes } from "./Documents";
import { apiUrls } from "../api/generated-operations";
import { apiQuery, liveDataEvent, useLiveJSON, useLivePage } from "../api/live-data";
import { type operations } from "../api/generated-api";
import { AppearanceIcon, collectionAppearance, projectAppearance } from "./AppearancePicker";
import { useActionDialog } from "./ActionDialog";
import { TranscriptHistory } from "./TranscriptHistory";
import { type LatestSummary, SummaryHistory } from "./SummaryHistory";
import { ServerSummaryGeneration } from "./SummaryGeneration";
import { RecordingIndicator } from "./RecordingIndicator";
import { useEffect, useMemo, useRef, useState } from "react";
import { navigateDashboard } from "../app/navigation";
import { canWriteWorkspace, clientMutationEvent, type SyncedMeetingInfo, type SyncedProjectInfo, type SyncedWorkspaceInfo, syncMessage, uiText } from "../api/api";
import { MeetingTabs, parseSummary, SummaryTags } from "./MeetingContent";
import { FileDialog, FileLink } from "./FileViewer";
import { MenuIcon, useSidebar } from "./Sidebar";
import { Tooltip } from "../components/Tooltip";
import { Button } from "../components/ui/button";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger } from "../components/ui/dropdown-menu";
import { MoreHorizontal } from "lucide-react";
import { commitSyncTransaction } from "../api/transactions";
import { BreadcrumbHeader, type BreadcrumbOption, projectBreadcrumbOptions, workspaceBreadcrumbOptions } from "./Breadcrumbs";
import { DataError } from "./DataError";

type SyncedScreenshotInfo = operations["listMeetingFiles"]["responses"][200]["content"]["application/json"]["items"][number];
function MeetingScreenshots({ meetingId }: { meetingId: string }) {
  const screenshotsQuery = useLivePage<SyncedScreenshotInfo>(apiQuery("listMeetingFiles", { params: { path: { meetingId } } }));
  const screenshots = screenshotsQuery.data?.items;
  const screenshotCursor = screenshotsQuery.data?.nextCursor;
  const loadingScreenshots = screenshotsQuery.loadingMore;
  const [screenshotPreview, setScreenshotPreview] = useState<{ fileId: string; capturedAt?: string | null }>();
  const [loadAfterFileId, setLoadAfterFileId] = useState<string>();
  const screenshotReturnFocus = useRef<{ fileId: string; element: HTMLAnchorElement } | undefined>(undefined);
  const visibleScreenshots = useMemo(() => screenshots?.filter((screenshot) => screenshot.file.metadata.source === "screenshot"), [screenshots]);
  const previewIndex = screenshotPreview ? visibleScreenshots?.findIndex((screenshot) => screenshot.file.id === screenshotPreview.fileId) ?? -1 : -1;
  const previousScreenshot = previewIndex > 0 ? visibleScreenshots?.[previewIndex - 1] : undefined;
  const nextScreenshot = previewIndex >= 0 ? visibleScreenshots?.[previewIndex + 1] : undefined;
  useEffect(() => {
    if (!loadAfterFileId) return;
    const loadedIndex = visibleScreenshots?.findIndex((screenshot) => screenshot.file.id === loadAfterFileId) ?? -1;
    const loadedNext = loadedIndex >= 0 ? visibleScreenshots?.[loadedIndex + 1] : undefined;
    if (loadedNext) {
      setScreenshotPreview({ fileId: loadedNext.file.id, capturedAt: loadedNext.capturedAt });
      setLoadAfterFileId(undefined);
    } else if (loadedIndex < 0 || screenshotsQuery.error || (!loadingScreenshots && !screenshotCursor)) {
      setLoadAfterFileId(undefined);
    } else if (!loadingScreenshots) {
      screenshotsQuery.loadMore();
    }
  }, [loadAfterFileId, loadingScreenshots, screenshotCursor, screenshotsQuery.error, visibleScreenshots]);
  const openScreenshot = (screenshot: SyncedScreenshotInfo, link?: HTMLAnchorElement) => {
    if (link) screenshotReturnFocus.current = { fileId: screenshot.file.id, element: link };
    setScreenshotPreview({ fileId: screenshot.file.id, capturedAt: screenshot.capturedAt });
  };
  const closeScreenshot = () => {
    const opener = screenshotReturnFocus.current;
    const returnFocus = opener?.element.isConnected ? opener.element : opener && [...globalThis.document.querySelectorAll<HTMLAnchorElement>(".screenshot-grid a")]
      .find((link) => link.getAttribute("href") === objectPath(opener.fileId));
    setScreenshotPreview(undefined);
    setLoadAfterFileId(undefined);
    returnFocus?.focus({ preventScroll: true });
  };
  return <>
    {screenshotPreview && <FileDialog fileId={screenshotPreview.fileId} capturedAt={screenshotPreview.capturedAt}
      onClose={closeScreenshot}
      onPrevious={previousScreenshot ? () => openScreenshot(previousScreenshot) : undefined}
      onNext={nextScreenshot ? () => openScreenshot(nextScreenshot) : screenshotCursor && !loadingScreenshots && !loadAfterFileId ? () => {
        setLoadAfterFileId(screenshotPreview.fileId);
      } : undefined} />}
    <DataError error={screenshotsQuery.error} retry={screenshotsQuery.reload} />
    {visibleScreenshots?.length === 0 && <p className="content-empty">{uiText("No screenshots", "スクリーンショットはありません")}</p>}
    <div className="screenshot-grid">
      {visibleScreenshots?.map((screenshot) => (
        <ScreenshotFigure key={screenshot.id} file={screenshot.file} capturedAt={screenshot.capturedAt} onOpen={(link) => openScreenshot(screenshot, link)} />
      ))}
    </div>
    {screenshotCursor && <button className="secondary load-more" disabled={loadingScreenshots} onClick={screenshotsQuery.loadMore}>
      {loadingScreenshots ? uiText("Loading…", "読み込み中…") : uiText("Load more", "さらに表示")}
    </button>}
  </>;
}
export function SyncedMeeting({ workspaceId, meetingId, resolvedMeeting, publicOrigin, serverAI = true }: { workspaceId: string; meetingId: string; resolvedMeeting?: SyncedMeetingInfo; publicOrigin?: string; serverAI?: boolean }) {
  const { dialog, openDialog } = useActionDialog();
  const optionsTrigger = useRef<HTMLButtonElement>(null);
  const summaryRestoreFocus = useRef<HTMLElement | null>(null);
  const { workspaces } = useSidebar();
  const meetingQuery = useLiveJSON<SyncedMeetingInfo>(resolvedMeeting ? undefined : apiQuery("getMeeting", { params: { path: { meetingId } } }));
  const workspaceQuery = useLiveJSON<SyncedWorkspaceInfo>(apiQuery("getWorkspace", { params: { path: { workspaceId: workspaceId } } }));
  const projectsQuery = useLiveJSON<{ items: SyncedProjectInfo[] }>(apiQuery("listProjects", { params: { path: { workspaceId: workspaceId } } }));
  const meeting = workspaceQuery.data ? resolvedMeeting ?? meetingQuery.data : undefined;
  const workspace = workspaceQuery.data;
  const [recovering, setRecovering] = useState(false);
  const latestSummary = useLiveJSON<LatestSummary>(apiQuery("getLatestSummary", { params: { path: { meetingId } } }));
  const [selectedSummary, setSelectedSummary] = useState<number | null>(null);
  useEffect(() => { setSelectedSummary(null); }, [meetingId]);
  const currentSummary = latestSummary.data?.record;
  const document = useMemo(() => parseSummary(currentSummary?.document ?? undefined), [currentSummary?.document]);
  const project = projectsQuery.data?.items.find((item) => item.projectId === meeting?.projectId);
  const parentProject = projectsQuery.data?.items.find((item) => item.projectId === project?.parentProjectId);
  const meetingFilters = meeting?.projectId ? { projectId: meeting.projectId, projectScope: "direct" as const } : { projectScope: "unassigned" as const };
  const siblingMeetings = useLivePage<SyncedMeetingInfo>(meeting ? apiQuery("listMeetings", { params: { path: { workspaceId }, query: meetingFilters } }) : undefined);
  const projects = projectsQuery.data?.items ?? [];
  const meetingBreadcrumbOptions: BreadcrumbOption[] = (siblingMeetings.data?.items ?? []).map((item) => ({ kind: "meeting", href: objectPath(item.meetingId),
    icon: <MenuIcon name="document" />, label: item.name || uiText("Untitled meeting", "無題のミーティング"), current: item.meetingId === meetingId }));
  const projectOptions = projectBreadcrumbOptions(projects, undefined, { projectId: project?.projectId, meetingId, meetings: siblingMeetings.data?.items });
  const workspaceOptions = workspaceBreadcrumbOptions(workspaces, workspaceId, projectOptions);
  const [summaryDialogOpen, setSummaryDialogOpen] = useState(false);
  const [notesStatus, setNotesStatus] = useState<HTMLElement | null>(null);
  const editMeeting = (restoreFocus?: HTMLElement | null) => {
    if (!meeting) return;
    openDialog({
      title: uiText("Edit Meeting", "ミーティングを編集"), confirmLabel: uiText("Save changes", "変更を保存"),
      fields: [
        { name: "name", label: uiText("Meeting name", "ミーティング名"), value: meeting.name, required: true },
        { name: "description", label: uiText("Description", "説明"), value: meeting.description, multiline: true },
      ],
      onSubmit: async ({ name, description }) => {
        await commitSyncTransaction(workspaceId, [{ entity: "meeting", action: "update", entityId: meetingId, baseRevision: meeting.revision,
          data: { projectId: meeting.projectId ?? null, name: name!.trim(), description: description ?? "", status: meeting.status,
            duration: meeting.duration ?? null, recordingStartedAt: meeting.recordingStartedAt ?? null, updatedAt: new Date().toISOString() } }], setRecovering);
      },
    }, restoreFocus);
  };
  const deleteMeeting = (restoreFocus?: HTMLElement | null) => {
    if (!meeting || !workspace) return;
    openDialog({ title: uiText("Move meeting to trash?", "ミーティングをごみ箱に移動しますか？"),
      description: uiText(`“${meeting.name}” will be eligible for permanent deletion after ${workspace.meetingDeletionGraceDays} days. Restore it from this Workspace's trash before cleanup.`, `「${meeting.name}」は${workspace.meetingDeletionGraceDays}日後に完全削除の対象となります。削除処理前であれば、ワークスペースのごみ箱から復旧できます。`),
      confirmLabel: uiText("Move to trash", "ごみ箱に移動"), destructive: true,
      onSubmit: async () => {
        await commitSyncTransaction(workspaceId, [{ entity: "meeting", action: "delete", entityId: meetingId, baseRevision: meeting.revision, data: {} }], setRecovering);
        navigateDashboard(objectPath(workspaceId));
      },
    }, restoreFocus);
  };
  return (
    <article className="main-column" aria-busy={!meeting && (meetingQuery.loading || workspaceQuery.loading)}>
      {meeting && <>
        <BreadcrumbHeader segments={[
            { label: workspace?.name ?? uiText("Workspace", "ワークスペース"), href: objectPath(workspaceId),
              icon: <AppearanceIcon appearance={collectionAppearance(workspace, "workspace")} />,
              menuLabel: uiText("Workspaces", "ワークスペース"), options: workspaceOptions },
            ...(parentProject ? [{ label: parentProject.name, href: objectPath(parentProject.projectId),
              icon: <AppearanceIcon appearance={projectAppearance(parentProject)} />,
              menuLabel: uiText("Projects", "プロジェクト"), options: projectOptions }] : []),
            ...(project ? [{ label: project.name, href: objectPath(project.projectId),
              icon: <AppearanceIcon appearance={projectAppearance(project, parentProject)} />,
              menuLabel: parentProject ? uiText(`Projects in ${parentProject.name}`, `${parentProject.name} 内のプロジェクト`) : uiText("Projects", "プロジェクト"),
              options: projectBreadcrumbOptions(projects, project.parentProjectId ?? undefined, { projectId: project.projectId, meetingId, meetings: siblingMeetings.data?.items }) }] : []),
            { kind: "meeting", current: true, label: meeting.name || uiText("Untitled meeting", "無題のミーティング"),
              menuLabel: project ? uiText(`Meetings in ${project.name}`, `${project.name} 内のミーティング`) : uiText("Unassigned meetings", "未分類のミーティング"),
              options: meetingBreadcrumbOptions },
          ]} actions={<>
            <div ref={setNotesStatus} role="status" className="flex items-center gap-3 px-2 text-xs text-muted-foreground empty:hidden" />
            <Tooltip label={uiText("Copy link", "リンクをコピーします")}>
              <Button variant="ghost" size="icon" aria-label={uiText("Copy meeting link", "ミーティングのリンクをコピー")} onClick={() => void navigator.clipboard.writeText(new URL(`${window.location.pathname}${window.location.search}${window.location.hash}`, publicOrigin ?? window.location.origin).href)}><MenuIcon name="link" /></Button>
            </Tooltip>
            {canWriteWorkspace(workspace?.role) && <DropdownMenu>
              <Tooltip label={uiText("Meeting options", "ミーティングのオプション")}><DropdownMenuTrigger asChild>
                <Button ref={optionsTrigger} variant="ghost" size="icon" className="data-[state=open]:bg-accent" aria-label={uiText("Meeting actions", "ミーティングの操作")}><MoreHorizontal className="size-4" /></Button>
              </DropdownMenuTrigger></Tooltip>
              <DropdownMenuContent align="end" sideOffset={6} className="w-[256px] max-w-[calc(100vw-16px)] rounded-xl border-border/80 p-1.5 shadow-lg">
                {serverAI && <DropdownMenuItem className="min-h-8 rounded-lg px-2.5 text-[13px]" disabled={!currentSummary} onSelect={() => { summaryRestoreFocus.current = optionsTrigger.current; setSummaryDialogOpen(true); }}><MenuIcon name="sparkles" />{uiText("Regenerate summary", "要約を再生成")}</DropdownMenuItem>}
                <DropdownMenuItem className="min-h-8 rounded-lg px-2.5 text-[13px]" onSelect={() => editMeeting(optionsTrigger.current)}><MenuIcon name="edit" />{uiText("Edit Meeting", "ミーティングを編集")}</DropdownMenuItem>
                <DropdownMenuSeparator className="-mx-0.5 my-1.5" />
                <DropdownMenuItem className="min-h-8 rounded-lg px-2.5 text-[13px] text-destructive focus:text-destructive" onSelect={() => deleteMeeting(optionsTrigger.current)}><MenuIcon name="trash" />{uiText("Move to trash", "ごみ箱に移動")}</DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>}
          </>} />
      <header className="mb-6">
        {serverAI && canWriteWorkspace(workspace?.role) && <ServerSummaryGeneration key={meetingId} meetingId={meetingId}
          workspaceId={meeting.workspaceId} open={summaryDialogOpen} onOpenChange={setSummaryDialogOpen} restoreFocus={summaryRestoreFocus.current} hasSummary={Boolean(currentSummary)} showTrigger={false} />}
        <h1 className="mb-4 break-words text-[28px] font-semibold leading-snug tracking-tight max-sm:text-2xl">{meeting.name || uiText("Untitled meeting", "無題のミーティング")}</h1>
        <div className="flex flex-wrap gap-1.5">
          <RecordingIndicator isRecording={meeting.isRecording} />
          <span className="metadata-chip"><time dateTime={meeting.recordingStartedAt ?? meeting.createdAt}>
            {new Date(meeting.recordingStartedAt ?? meeting.createdAt).toLocaleString(undefined, { year: "numeric", month: "long", day: "numeric", hour: "2-digit", minute: "2-digit" })}
          </time>{meeting.duration != null && <> · {Math.floor(meeting.duration / 60)}:{String(Math.floor(meeting.duration % 60)).padStart(2, "0")}</>}</span>
          {meeting.projectId ? <a className="metadata-chip" href={objectPath(meeting.projectId)}>
            <AppearanceIcon appearance={projectAppearance(project, parentProject)} size={14} />{project?.path ?? uiText("Project", "プロジェクト")}
          </a> : <span className="metadata-chip">{uiText("Unassigned", "未分類")}</span>}
          <SummaryTags document={document} />
        </div>
        {meeting.description?.trim() && <details className="meeting-description"><summary>{uiText("Description", "説明")}</summary><p>{meeting.description}</p></details>}
      </header></>}
      {dialog}
      {recovering && <p role="status">{syncMessage("sync_recovering")}</p>}
      <DataError error={meetingQuery.error} retry={meetingQuery.reload} />
      <DataError error={workspaceQuery.error} retry={workspaceQuery.reload} />
      <DataError error={projectsQuery.error} retry={projectsQuery.reload} />
      {meeting && <MeetingTabs
        notes={<MeetingNotes key={meetingId} workspaceId={workspaceId} meetingId={meetingId} editable={workspace?.role === "admin" || workspace?.role === "editor"} statusSlot={notesStatus} />}
        summary={<>
          <DataError error={latestSummary.error} retry={latestSummary.reload} />
          <SummaryHistory key={meetingId} meetingId={meetingId} latest={latestSummary.data} selected={selectedSummary} onSelect={setSelectedSummary} />
        </>}
        screenshots={<MeetingScreenshots key={meetingId} meetingId={meetingId} />}
        transcript={<TranscriptHistory key={meetingId} meetingId={meetingId} timeBase={meeting.recordingStartedAt ?? meeting.createdAt} />}
      />}
    </article>
  );
}

export function ScreenshotFigure({ file, capturedAt, onOpen }: {
  file: SyncedScreenshotInfo["file"]; capturedAt?: string | null;
  onOpen?: (link: HTMLAnchorElement) => void;
}) {
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    const retry = () => setFailed(false);
    const events = [liveDataEvent, clientMutationEvent, "online"];
    for (const event of events) window.addEventListener(event, retry);
    return () => { for (const event of events) window.removeEventListener(event, retry); };
  }, []);
  const original = apiUrls.getFileContent({ params: { path: { fileId: file.id } } });
  return <figure className="panel">
    <FileLink fileId={file.id} capturedAt={capturedAt} onOpen={onOpen} label={uiText("Open screenshot", "スクリーンショットを開く")}>
      {failed ? <span role="alert">{uiText("Unable to load screenshot.", "スクリーンショットを読み込めませんでした。")}</span> : <img
        src={file.variants?.thumb_480 ?? original}
        alt={file.metadata.caption || uiText("Screenshot", "スクリーンショット")}
        loading="lazy"
        onError={() => setFailed(true)}
      />}
    </FileLink>
    {failed && <button className="secondary" onClick={() => setFailed(false)}>{uiText("Retry", "再試行")}</button>}
    {capturedAt && <time className="mt-3 block text-xs text-muted-foreground" dateTime={capturedAt}>{new Date(capturedAt).toLocaleTimeString()}</time>}
    {(file.metadata.caption || file.metadata.ocrText) && <figcaption>{file.metadata.caption || file.metadata.ocrText}</figcaption>}
    <a href={original} download>{uiText("Download original", "原本をダウンロード")}</a>
  </figure>;
}
