// Public `@dahlia-ai/server/client` contract. Add names deliberately; internal modules are not exported.
export { App, type AppProps } from "./App";
export {
  resolveDashboardExtensionRoute,
  type DashboardBrand,
  type DashboardExtension,
  type DashboardExtensionRoute,
  type DashboardNavigationItem,
  type SessionInfo,
} from "./app/dashboard";
export {
  isChatPath,
  isCoreDashboardPath,
  resolveDashboardRoute,
  shouldRedirectToSignIn,
  type DashboardCapabilities,
  type DashboardRoute,
} from "./app/routes";
export { accountSignInRequired } from "./api/auth";
export { commitSyncTransaction } from "./api/transactions";
export { HeaderAuthenticationNotice, OAuthConsentDetails } from "./screens/SignIn";
export { MeetingList, Workspaces, WorkspaceMeetings, WorkspaceTrash } from "./screens/Workspaces";
export { BreadcrumbHeader, projectBreadcrumbOptions } from "./screens/Breadcrumbs";
export { ScreenshotFigure, SyncedMeeting } from "./screens/Meeting";
export { Organization } from "./screens/Organizations";
export { AdminOrganization, AdminSearchSettings } from "./screens/Admin";
