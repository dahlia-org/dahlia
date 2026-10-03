import { encodeId } from "../typeid";
import { apiOperations as api } from "./generated-operations";
import { type components } from "./generated-api";
import { refreshData } from "./live-data";
import { RequestError, syncMessage } from "./api";
import { uuidV7 } from "../id";

type WithoutOperationId<T> = T extends unknown ? Omit<T, "id"> : never;
type SyncOperation = WithoutOperationId<components["schemas"]["Transaction"]["operations"][number]>;

export async function commitSyncTransaction(workspaceId: string, operations: SyncOperation[], onRecovery: (active: boolean) => void = () => {}) {
  const transactionId = encodeId("transaction", uuidV7());
  const request = {
    body: {
      schemaVersion: 3 as const,
      id: transactionId,
      workspaceId,
      createdAt: new Date().toISOString(),
      operations: operations.map((operation) => ({ ...operation, id: encodeId("operation", uuidV7()) })),
    },
  };
  type Receipt = { id: string; status: "committed" | "unknown"; receipt?: "full" | "compact" };
  try {
    let result: Receipt;
    try {
      result = await api.commitTransaction(request, false);
    } catch (error) {
      if (error instanceof RequestError && error.status && error.status < 500 && ![408, 410, 425, 429].includes(error.status)) throw error;
      onRecovery(true);
      let resolved: Receipt;
      try {
        resolved = await api.resolveTransaction(request, false);
      } catch (resolveError) {
        if (resolveError instanceof RequestError && resolveError.status === 404) {
          throw new RequestError(syncMessage("sync_upgrade_required")!, 426, { cause: resolveError });
        }
        throw resolveError;
      }
      if (resolved.id !== transactionId) throw new Error("Invalid transaction receipt", { cause: error });
      result = resolved.status === "unknown"
        ? await api.commitTransaction(request, false)
        : resolved;
    }
    if (result.id !== transactionId || result.status !== "committed"
      || (result.receipt !== undefined && !["full", "compact"].includes(result.receipt))) {
      throw new Error("Invalid transaction receipt");
    }
    // Both receipt forms acknowledge the write. Callers reload canonical data rather than applying old content.
    if (typeof window !== "undefined") refreshData();
    return result;
  } finally {
    onRecovery(false);
  }
}

export async function createWorkspaceRecord(organizationId: string, name: string, encryption: string | undefined, onRecovery: (active: boolean) => void) {
  const id = encodeId("workspace", uuidV7());
  await commitSyncTransaction(id, [{ entity: "workspace", action: "create", entityId: id, baseRevision: null,
    data: { organizationId, name: name.trim(), ...(encryption === "server" ? { encryption: "server" as const } : {}), createdAt: new Date().toISOString() } }], onRecovery);
  return id;
}
