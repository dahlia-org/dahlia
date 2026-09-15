import { testUserID } from "./public-test-client";
import type { AuthStore } from "../src/auth/store";
import { DEFAULT_SEARCH_SETTINGS } from "../src/search/settings-model";

export function testStore(overrides: Partial<AuthStore> = {}): AuthStore {
  let searchWeights = { ...DEFAULT_SEARCH_SETTINGS };
  return {
    database: {} as AuthStore["database"],
    organizations: { hasMember: async () => false, candidates: async () => [], requests: async () => [], join: async () => {}, resolveRequest: async () => {}, create: async () => { throw new Error("Unavailable"); }, delete: async () => {}, getDomains: async () => ({ domains: [] }), updateDomains: async () => ({ domains: [] }), initializeUser: async () => {},
      transaction: async () => { throw new Error("Organization mutations unavailable in this fixture"); }, addTeamCreator: async () => {}, assertTeamOrganization: async () => {} },
    searchSettings: {
      get: () => Promise.resolve({ ...searchWeights }),
      update: (weights) => { searchWeights = { ...weights }; return Promise.resolve({ ...searchWeights }); },
    },
    sync: {
      purgeDeletedMeetings: () => Promise.resolve(0),
      expireRecordingUploads: async () => {},
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
    resolveHeaderUser: (identity) => Promise.resolve(testUserID(identity.userId)),
    ensureIdentityUser: () => Promise.resolve(true),
    seedDahliaClient: () => Promise.resolve(),
    listDahliaSessions: () => Promise.resolve([]),
    revokeDahliaSession: () => Promise.resolve(false),
    listServerUsers: () => Promise.resolve([]),
    listServerOrganizations: () => Promise.resolve([]),
    getServerOrganization: () => Promise.resolve(null),
    listAdminUsers: () => Promise.resolve([]),
    isAdminUser: () => Promise.resolve(false),
    addAdminUser: () => Promise.resolve(null),
    removeAdminUser: () => Promise.resolve("not_found"),
    ...overrides,
  };
}
