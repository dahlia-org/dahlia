CREATE TABLE "artifactReservation" (
  "id" TEXT PRIMARY KEY NOT NULL
);

INSERT INTO "artifactReservation" ("id") SELECT "id" FROM "artifact";
