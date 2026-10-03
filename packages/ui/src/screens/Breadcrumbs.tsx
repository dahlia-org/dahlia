import { objectPath } from "../model/object-url";
import { AppearanceIcon, collectionAppearance, projectAppearance } from "./AppearancePicker";
import { HoverCard as HoverCardPrimitive } from "radix-ui";
import { type ReactNode } from "react";
import { type SyncedMeetingInfo, type SyncedProjectInfo, type SyncedWorkspaceInfo, uiText } from "../api/api";
import { MenuIcon } from "./Sidebar";
import { HoverCard, HoverCardContent, HoverCardTrigger } from "../components/ui/hover-card";
import { ChevronRight } from "lucide-react";
import { DetailHeaderBar } from "../layout/AppShell";

export type BreadcrumbOption = { kind?: "meeting"; href: string; icon?: ReactNode; label: string; current?: boolean; children?: BreadcrumbOption[]; childrenLabel?: string };
type BreadcrumbSegment = Omit<BreadcrumbOption, "children" | "childrenLabel" | "href"> & { href?: string; menuLabel: string; options: BreadcrumbOption[] };

export function workspaceBreadcrumbOptions(workspaces: SyncedWorkspaceInfo[] | undefined, workspaceId: string, children: BreadcrumbOption[]): BreadcrumbOption[] {
  return (workspaces ?? []).map((workspace) => ({
    href: objectPath(workspace.workspaceId),
    icon: <AppearanceIcon appearance={collectionAppearance(workspace, "workspace")} />,
    label: workspace.name,
    current: workspace.workspaceId === workspaceId,
    children: workspace.workspaceId === workspaceId ? children : undefined,
    childrenLabel: uiText(`Projects in ${workspace.name}`, `${workspace.name} のプロジェクト`),
  }));
}

export function projectBreadcrumbOptions(projects: SyncedProjectInfo[], parentId?: string, context: {
  meetings?: SyncedMeetingInfo[];
  meetingId?: string;
  projectId?: string;
} = {}): BreadcrumbOption[] {
  return projects.filter((item) => (item.parentProjectId ?? undefined) === parentId).map((item) => {
    const children = projectBreadcrumbOptions(projects, item.projectId, context);
    if (item.projectId === context.projectId) children.push(...(context.meetings ?? []).map((meeting) => ({
      kind: "meeting" as const, href: objectPath(meeting.meetingId), icon: <MenuIcon name="document" />,
      label: meeting.name || uiText("Untitled meeting", "無題のミーティング"), current: meeting.meetingId === context.meetingId,
    })));
    return { href: objectPath(item.projectId),
      icon: <AppearanceIcon appearance={projectAppearance(item, projects.find((parent) => parent.projectId === item.parentProjectId))} />,
      label: item.name, current: item.projectId === context.projectId, children,
      childrenLabel: uiText(`Contents of ${item.name}`, `${item.name} の内容`) };
  });
}

function BreadcrumbOptions({ options, label }: { options: BreadcrumbOption[]; label: string }) {
  return <nav className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-0.5" aria-label={label}>{options.map((option) => {
    const hasChildren = Boolean(option.children?.length);
    const link = <a key={option.href} className="flex min-w-0 items-center gap-2 rounded-md px-2 py-1.5 text-xs hover:bg-accent aria-[current=page]:bg-accent [&>svg]:shrink-0" aria-current={option.current ? "page" : undefined} href={option.href} title={option.label} data-breadcrumb-submenu-trigger={hasChildren || undefined}>
      {option.icon}<span className="min-w-0 flex-1 truncate">{option.label}</span>{hasChildren && <ChevronRight className="size-3.5 shrink-0 text-muted-foreground" aria-hidden="true" />}
    </a>;
    if (!hasChildren) return link;
    // Keep submenu content inline so moving into it stays inside the parent hover card.
    return <HoverCard key={option.href} openDelay={0} closeDelay={150}>
      <HoverCardTrigger asChild>{link}</HoverCardTrigger>
      <HoverCardPrimitive.Content side="right" align="start" sideOffset={4} collisionPadding={12} className="breadcrumb-submenu" data-wide={option.children!.some((child) => child.kind === "meeting") || undefined}>
        <BreadcrumbOptions options={option.children!} label={option.childrenLabel ?? option.label} />
      </HoverCardPrimitive.Content>
    </HoverCard>;
  })}</nav>;
}

function BreadcrumbSwitcher({ label, href, icon, menuLabel, options, kind, current = false }: BreadcrumbSegment) {
  const triggerClass = "breadcrumb-trigger inline-flex min-w-0 items-center gap-1.5 rounded-md px-1.5 py-1 text-xs text-muted-foreground outline-none hover:bg-accent hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring";
  const trigger = href
    ? <a className={triggerClass} data-kind={kind} title={label} href={href}>{icon}<span className="truncate">{label}</span></a>
    : <button type="button" className={triggerClass} data-kind={kind} title={label} aria-current={current ? "page" : undefined}>{icon}<span className="truncate">{label}</span></button>;
  if (!options.length) return trigger;
  const menuWidth = kind === "meeting" || options.some((option) => option.kind === "meeting")
    ? "w-[min(520px,calc(100vw-24px))]"
    : "w-[min(260px,calc(100vw-24px))]";
  return <HoverCard openDelay={300} closeDelay={150}>
    <HoverCardTrigger asChild>{trigger}</HoverCardTrigger>
    <HoverCardContent align="start" className={`p-1 ${menuWidth}`}>
      <p className="truncate px-2 py-1.5 text-[11px] font-medium text-muted-foreground" title={menuLabel}>{menuLabel}</p>
      <BreadcrumbOptions options={options} label={menuLabel} />
    </HoverCardContent>
  </HoverCard>;
}

export function BreadcrumbHeader({ segments, actions }: { segments: BreadcrumbSegment[]; actions?: ReactNode }) {
  return <DetailHeaderBar actions={actions} className="-mt-6 mb-12">
    <nav className="flex min-w-0 flex-1 items-center gap-1 overflow-visible whitespace-nowrap" aria-label={uiText("Breadcrumbs", "パンくず")}>
      {segments.map((segment, index) => <span className="contents" key={`${segment.href ?? "current"}:${segment.label}`}>
        {index > 0 && <span className="text-xs text-muted-foreground" aria-hidden="true">/</span>}
        <BreadcrumbSwitcher {...segment} />
      </span>)}
    </nav>
  </DetailHeaderBar>;
}
