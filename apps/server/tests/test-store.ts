import type { AuthStore } from "../src/auth/store";
import { DEFAULT_ACCOUNT_SETTINGS, type AccountSettings } from "../src/account-settings";

export function testStore(overrides: Partial<AuthStore> = {}): AuthStore {
  const settings = new Map<string, AccountSettings>();
  return {
    database: {} as AuthStore["database"],
    accountSettings: {
      getChangeVersion: (userId) => Promise.resolve(settings.has(userId) ? 1 : null),
      get: (userId) => Promise.resolve(settings.get(userId) ?? null),
      update: (userId, patch, initialize) => {
        const current = settings.get(userId) ?? DEFAULT_ACCOUNT_SETTINGS;
        const value = initialize && settings.has(userId) ? settings.get(userId)!
          : { ...current, ...patch, summary: {
            detail: patch.summary?.detail ?? current.summary.detail,
            method: patch.summary?.method ?? current.summary.method,
            methodSettings: { audio: { ...current.summary.methodSettings.audio, ...patch.summary?.methodSettings?.audio }, transcript: { ...current.summary.methodSettings.transcript, ...patch.summary?.methodSettings?.transcript } },
          } };
        settings.set(userId, value);
        return Promise.resolve(value);
      },
    },
    sync: {
      isAvailable: () => Promise.resolve(false),
      listHistoryTargets: () => Promise.resolve([]),
      pruneHistoryBatch: () => Promise.resolve({ changesDeleted: 0, receiptsCompacted: 0 }),
      withIdentity: () => Promise.reject(new Error("sync unavailable in this test")),
      claimStorageDeletes: () => Promise.resolve([]),
      hasStorageDelete: () => Promise.resolve(false),
      enqueueStorageDelete: () => Promise.resolve(),
      isStorageDeleteClaimCurrent: () => Promise.resolve(false),
      completeStorageDelete: () => Promise.resolve(),
      failStorageDelete: () => Promise.resolve(),
      withStorageKeyLock: (_storageKey, action) => action(),
    },
    ensureIdentityUser: () => Promise.resolve(true),
    seedDahliaClient: () => Promise.resolve(),
    listDahliaSessions: () => Promise.resolve([]),
    revokeDahliaSession: () => Promise.resolve(false),
    listAdminUsers: () => Promise.resolve([]),
    isAdminUser: () => Promise.resolve(false),
    addAdminUser: () => Promise.resolve(null),
    removeAdminUser: () => Promise.resolve("not_found"),
    getExternalOrganization: () => Promise.resolve(null),
    listExternalOrganizationMembers: () => Promise.resolve(null),
    listExternalTeams: () => Promise.resolve(null),
    createExternalTeam: () => Promise.resolve(null),
    updateExternalTeam: () => Promise.resolve(null),
    deleteExternalTeam: () => Promise.resolve(false),
    listExternalTeamMembers: () => Promise.resolve(null),
    addExternalTeamMember: () => Promise.resolve(false),
    removeExternalTeamMember: () => Promise.resolve(false),
    deleteVaultPermissionsForPrincipal: () => Promise.resolve(),
    deleteVaultPermissionsForOrganization: () => Promise.resolve(),
    ...overrides,
  };
}
