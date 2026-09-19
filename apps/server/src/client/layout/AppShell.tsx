import { useEffect, useRef, useState, type ReactNode } from "react";
import type { SessionInfo } from "../App";
import type { SyncedMeetingInfo } from "../api";
import { uiText } from "../api";
import { dashboardNavigationEvent, dashboardNavigationPath } from "../navigation";
import { MenuIcon, Sidebar, SidebarProvider } from "../Sidebar";
import { Tooltip } from "../Tooltip";
import { Button } from "../components/ui/button";
import { DropdownMenuItem } from "../components/ui/dropdown-menu";
import { Sheet, SheetContent, SheetTitle } from "../components/ui/sheet";

export function AppShell({ brand, children, extensionPaths, navigate, path, routeMeeting, routeMeetingOwned,
  routeWorkspaceId, serverLinks, session }: {
  brand: ReactNode;
  children: ReactNode;
  extensionPaths: string[];
  navigate: (path: string) => void;
  path: string;
  routeMeeting?: SyncedMeetingInfo;
  routeMeetingOwned?: boolean;
  routeWorkspaceId?: string;
  serverLinks?: ReactNode;
  session: SessionInfo;
}) {
  const main = useRef<HTMLElement>(null);
  const [navigationOpen, setNavigationOpen] = useState(false);
  const [compact, setCompact] = useState(() => window.matchMedia("(max-width: 767px)").matches);
  useEffect(() => {
    const media = window.matchMedia("(max-width: 767px)");
    const update = () => { setNavigationOpen(false); setCompact(media.matches); };
    update();
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);
  useEffect(() => {
    setNavigationOpen(false);
    main.current?.focus({ preventScroll: true });
    window.scrollTo(0, 0);
  }, [path]);
  useEffect(() => {
    const closeNavigation = () => setNavigationOpen(false);
    window.addEventListener(dashboardNavigationEvent, closeNavigation);
    return () => window.removeEventListener(dashboardNavigationEvent, closeNavigation);
  }, []);
  useEffect(() => {
    const followLink = (event: MouseEvent) => {
      if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      const link = event.target instanceof Element ? event.target.closest("a") : null;
      if (!link || !link.hasAttribute("href") || link.hasAttribute("download") || (link.target && link.target !== "_self")) return;
      const next = dashboardNavigationPath(link.href, window.location.href, extensionPaths);
      if (!next) return;
      event.preventDefault();
      navigate(next);
    };
    document.addEventListener("click", followLink);
    return () => document.removeEventListener("click", followLink);
  }, [extensionPaths, navigate]);
  const sidebar = <Sidebar brand={brand} session={session} routeWorkspaceId={routeWorkspaceId} routeMeeting={routeMeeting} routeMeetingOwned={routeMeetingOwned} serverLinks={serverLinks}>
    <DropdownMenuItem asChild><a aria-current={path === "/dashboard/settings" ? "page" : undefined} href="/dashboard/settings">
      <MenuIcon name="settings" />{uiText("Account settings", "アカウント設定")}
    </a></DropdownMenuItem>
  </Sidebar>;
  return <SidebarProvider key={session.user.id} session={session}>
    <div className="grid min-h-dvh min-w-0 md:grid-cols-[240px_minmax(0,1fr)]">
      <a className="fixed left-3 top-3 z-[100] -translate-y-16 rounded-md bg-primary px-3 py-2 text-sm text-primary-foreground focus:translate-y-0" href="#main-content">{uiText("Skip to content", "本文へ移動")}</a>
      <header className="flex h-11 items-center gap-2 px-3 md:hidden">
        <Tooltip label={uiText("Open navigation", "ナビゲーションを開く")}><Button variant="ghost" size="icon" aria-label={uiText("Open navigation", "ナビゲーションを開く")} aria-controls="primary-navigation" onClick={() => setNavigationOpen(true)}><MenuIcon name="menu" /></Button></Tooltip>
        {brand}
      </header>
      {!compact && <div id="primary-navigation" className="sticky top-0 h-dvh min-w-0">{sidebar}</div>}
      {compact && <Sheet open={navigationOpen} onOpenChange={setNavigationOpen}>
        <SheetContent id="primary-navigation" side="left" className="w-[min(300px,88vw)] p-0" aria-label={uiText("Navigation", "ナビゲーション")}>
          <SheetTitle className="sr-only">{uiText("Navigation", "ナビゲーション")}</SheetTitle>{sidebar}
        </SheetContent>
      </Sheet>}
      <main id="main-content" className={path === "/ai" ? "min-w-0 outline-none md:col-start-2" : "min-w-0 px-5 pb-16 pt-7 outline-none sm:px-8 md:col-start-2 md:px-10 lg:px-14"} key={path} ref={main} tabIndex={-1}>{children}</main>
    </div>
  </SidebarProvider>;
}

export function PageHeader({ title, description, actions }: { title: string; description?: string; actions?: ReactNode }) {
  return <header className="mb-8 flex items-start justify-between gap-6"><div className="min-w-0"><h1 className="text-2xl font-semibold tracking-tight">{title}</h1>{description && <p className="mt-2 max-w-2xl text-sm leading-6 text-muted-foreground">{description}</p>}</div>{actions}</header>;
}

export function DetailHeaderBar({ children, actions, className = "" }: { children: ReactNode; actions?: ReactNode; className?: string }) {
  return <div className={`relative left-1/2 flex h-9 w-[calc(100vw-240px)] -translate-x-1/2 items-center gap-3 px-4 max-md:w-screen ${className}`}>
    {children}
    {actions && <div className="flex shrink-0 items-center gap-1">{actions}</div>}
  </div>;
}
