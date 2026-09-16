import type { AuthStore } from "../src/auth/store";
import type { Identity } from "../src/auth/identity";
import { MeetingSyncService } from "../src/sync/service";
import { uuidV7 } from "../src/id";
import { workspaceGenerationSettingsSchema, type WorkspaceGenerationSettings } from "../src/workspace-generation-settings";

type Remote = WorkspaceGenerationSettings["processing"]["remote"];
type Patch = Omit<Partial<WorkspaceGenerationSettings>, "processing"> & {
  processing?: { location?: "local" | "remote"; remote?: { [K in keyof Remote]?: Remote[K] | null } };
};
export async function generationSettings(store: AuthStore, identity: Identity, workspaceId: string) {
  const workspace = await store.sync.withIdentity(identity, (scoped) => scoped.getWorkspace(workspaceId));
  if (!workspace) throw new Error("Workspace unavailable");
  return workspace.generationSettings;
}
export async function updateGenerationSettings(store: AuthStore, identity: Identity, workspaceId: string, patch: Patch) {
  const workspace = await store.sync.withIdentity(identity, (scoped) => scoped.getWorkspace(workspaceId));
  if (!workspace) throw new Error("Workspace unavailable");
  const previous = workspace.generationSettings;
  const remote = { ...previous.processing.remote, ...patch.processing?.remote };
  for (const key of ["summaryModel", "reasoningEffort"] as const) if (remote[key] === null) delete remote[key];
  const settings = workspaceGenerationSettingsSchema.parse({ ...previous, ...patch,
    processing: { ...previous.processing, ...patch.processing, remote } });
  await new MeetingSyncService(store.sync).commitTransaction(identity, { schemaVersion: 3, id: uuidV7(), workspaceId,
    createdAt: new Date().toISOString(), operations: [{ id: uuidV7(), entity: "workspace", action: "update", entityId: workspaceId,
      baseRevision: workspace.revision, data: { name: workspace.name, generationSettings: settings } }] });
  return settings;
}
