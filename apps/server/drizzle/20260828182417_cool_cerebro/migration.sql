CREATE TABLE "dahlia"."artifact_reservation" (
	"id" text PRIMARY KEY
);

INSERT INTO "dahlia"."artifact_reservation" ("id") SELECT "id" FROM "dahlia"."artifact";
