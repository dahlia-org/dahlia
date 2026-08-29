CREATE TABLE "artifact" (
  "id" TEXT PRIMARY KEY NOT NULL,
  "ownerWorkspaceId" TEXT NOT NULL,
  "contentType" TEXT NOT NULL,
  "visibility" TEXT NOT NULL DEFAULT 'private',
  "createdAt" DATE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "artifact_visibility_check" CHECK("artifact"."visibility" IN ('private', 'public'))
);
