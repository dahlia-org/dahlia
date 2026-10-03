// Public `@dahlia-ai/server/client` contract. Add names deliberately; internal modules are not exported.
export { App, type AppProps } from "./App";
export {
  resolveDashboardExtensionRoute,
  type DashboardBrand,
  type DashboardExtension,
  type DashboardExtensionRoute,
  type DashboardNavigationItem,
  type SessionInfo,
} from "./dashboard";
export {
  isChatPath,
  isCoreDashboardPath,
  resolveDashboardRoute,
  shouldRedirectToSignIn,
  type DashboardCapabilities,
  type DashboardRoute,
} from "./routes";
export { accountSignInRequired } from "./auth";
export { commitSyncTransaction } from "./transactions";
export { HeaderAuthenticationNotice, OAuthConsentDetails } from "./SignIn";
export { MeetingList, Workspaces, WorkspaceMeetings, WorkspaceTrash } from "./Workspaces";
export { BreadcrumbHeader, projectBreadcrumbOptions } from "./Breadcrumbs";
export { ScreenshotFigure, SyncedMeeting } from "./Meeting";
export { Organization } from "./Organizations";
export { AdminOrganization, AdminSearchSettings } from "./Admin";
