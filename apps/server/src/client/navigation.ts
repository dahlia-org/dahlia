import { isCoreDashboardPath } from "./routes";

export function dashboardNavigationPath(href: string, currentURL: string): string | undefined {
  const current = new URL(currentURL);
  const target = new URL(href, current);
  if (target.origin !== current.origin || target.search || target.hash || !isCoreDashboardPath(target.pathname)) return;
  return target.pathname;
}
