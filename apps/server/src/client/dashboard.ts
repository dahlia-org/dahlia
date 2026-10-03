import { type ComponentType, useEffect, useState } from "react";
import { clientMutationEvent, RequestError } from "./api";
import { apiOperations as api } from "./generated-operations";
import { subscribeLiveUpdates } from "./live-data";
import { type DashboardCapabilities, isCoreDashboardPath, shouldRedirectToSignIn } from "./routes";

export interface SessionInfo {
  capabilities: DashboardCapabilities;
  user: { id: string; email?: string; name?: string };
}

export interface DashboardBrand {
  name: string;
  product: string;
}

export interface DashboardNavigationItem {
  capability?: string;
  label: string;
  path: string;
}

export function isServerNavigation(item: DashboardNavigationItem): boolean {
  return item.capability === "admin" || item.path.startsWith("/admin/");
}

export interface DashboardExtensionRoute {
  capability?: string;
  component: ComponentType<{ session: SessionInfo }>;
  path: string;
}

export interface DashboardExtension {
  navigation?: readonly DashboardNavigationItem[];
  routes?: readonly DashboardExtensionRoute[];
}

export function resolveDashboardExtensionRoute(
  path: string,
  capabilities: DashboardCapabilities,
  extensions: readonly DashboardExtension[],
): { allowed: boolean; route?: DashboardExtensionRoute } {
  if (isCoreDashboardPath(path)) return { allowed: true };
  const route = extensions
    .flatMap((extension) => extension.routes ?? [])
    .find((candidate) => candidate.path === path);
  return {
    allowed: !route?.capability || capabilities[route.capability] === true,
    route,
  };
}

/** Owns the account session, expiry redirect and the account's live-update subscription. */
export function useDashboardSession(path: string) {
  const needsSession = path !== "/sign-in" && path !== "/oauth/consent";
  const [session, setSession] = useState<SessionInfo>();
  const [sessionError, setSessionError] = useState<string>();
  const [unauthorized, setUnauthorized] = useState(false);
  const [sessionAttempt, setSessionAttempt] = useState(0);

  useEffect(() => {
    if (!needsSession) return;
    const sessionExpired = () => setUnauthorized(true);
    const refreshSession = () => setSessionAttempt((attempt) => attempt + 1);
    window.addEventListener("dahlia:unauthorized", sessionExpired);
    window.addEventListener(clientMutationEvent, refreshSession);
    return () => {
      window.removeEventListener("dahlia:unauthorized", sessionExpired);
      window.removeEventListener(clientMutationEvent, refreshSession);
    };
  }, [needsSession]);

  useEffect(() => {
    if (unauthorized) window.location.replace(`/sign-in?next=${encodeURIComponent(path)}`);
  }, [unauthorized, path]);

  useEffect(() => {
    if (!needsSession) return;
    const controller = new AbortController();
    setSessionError(undefined);
    void api.getSession({ signal: controller.signal })
      .then((value) => { if (!controller.signal.aborted) setSession(value); })
      .catch((caught: unknown) => {
        if (controller.signal.aborted) return;
        if (shouldRedirectToSignIn(caught instanceof RequestError ? caught.status : undefined)) {
          setUnauthorized(true);
          return;
        }
        setSessionError(caught instanceof Error ? caught.message : "Could not load your account");
      });
    return () => controller.abort();
  }, [needsSession, sessionAttempt]);

  const syncEnabled = session?.capabilities.sync;
  const userId = session?.user.id;
  useEffect(() => {
    if (!needsSession || unauthorized || !userId || !syncEnabled) return;
    return subscribeLiveUpdates(userId);
  }, [needsSession, unauthorized, userId, syncEnabled]);

  return { session, sessionError, unauthorized, retrySession: () => setSessionAttempt((attempt) => attempt + 1) };
}
