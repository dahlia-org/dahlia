import type { AuthStore } from "../src/auth/store";

export function testStore(overrides: Partial<AuthStore> = {}): AuthStore {
  return {
    database: {} as AuthStore["database"],
    seedDahliaClient: () => Promise.resolve(),
    listDahliaSessions: () => Promise.resolve([]),
    revokeDahliaSession: () => Promise.resolve(false),
    listModelAliases: () => Promise.resolve([]),
    getEnabledModelAlias: () => Promise.resolve(null),
    createModelAlias: () => Promise.resolve(false),
    updateModelAlias: () => Promise.resolve(false),
    deleteModelAlias: () => Promise.resolve(false),
    listPlatformAdmins: () => Promise.resolve([]),
    isPlatformAdmin: () => Promise.resolve(false),
    addPlatformAdmin: () => Promise.resolve(false),
    deletePlatformAdmin: () => Promise.resolve(false),
    getArtifact: () => Promise.resolve(null),
    createArtifact: () => Promise.resolve(false),
    touchArtifact: () => Promise.resolve(null),
    updateArtifactVisibility: () => Promise.resolve(null),
    deleteArtifact: () => Promise.resolve(false),
    ...overrides,
  };
}
