import { isCoreDashboardPath } from "./routes";

export const dashboardNavigationEvent = "dahlia:navigate";

export function dashboardNavigationPath(href: string, currentURL: string, extensionPaths: readonly string[] = []): string | undefined {
  const current = new URL(currentURL);
  const target = new URL(href, current);
  if (target.origin !== current.origin || target.search || target.hash || (!isCoreDashboardPath(target.pathname) && !extensionPaths.includes(target.pathname))) return;
  return target.pathname;
}

export function navigateDashboard(path: string, replace = false) {
  // A same-page selection still completes navigation, without adding history.
  window.dispatchEvent(new Event(dashboardNavigationEvent));
  if (path === window.location.pathname) return;
  if (replace) window.history.replaceState(null, "", path);
  else window.history.pushState(null, "", path);
  window.dispatchEvent(new PopStateEvent("popstate"));
}
