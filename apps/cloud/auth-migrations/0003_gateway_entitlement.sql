CREATE TABLE "gatewayEntitlement" (
  "referenceId" TEXT PRIMARY KEY NOT NULL REFERENCES "user" ("id") ON DELETE CASCADE,
  "stripeSubscriptionId" TEXT NOT NULL UNIQUE,
  "plan" TEXT NOT NULL,
  "status" TEXT NOT NULL,
  "periodEnd" DATE,
  "cancelAtPeriodEnd" INTEGER NOT NULL DEFAULT 0,
  "cancelAt" DATE,
  "canceledAt" DATE,
  "endedAt" DATE,
  "eventCreated" INTEGER NOT NULL,
  "eventId" TEXT NOT NULL
);

CREATE TABLE "modelAlias" (
  "alias" TEXT PRIMARY KEY NOT NULL,
  "upstreamModel" TEXT NOT NULL,
  "displayName" TEXT,
  "enabled" INTEGER NOT NULL DEFAULT 1,
  "createdAt" DATE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" DATE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE "platformAdmin" (
  "email" TEXT PRIMARY KEY NOT NULL,
  "createdAt" DATE NOT NULL DEFAULT CURRENT_TIMESTAMP
);
