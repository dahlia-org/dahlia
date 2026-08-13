ALTER TABLE "user" ADD COLUMN "stripeCustomerId" TEXT;
ALTER TABLE "session" ADD COLUMN "activeOrganizationId" TEXT;

CREATE TABLE "organization" (
  "id" TEXT PRIMARY KEY NOT NULL,
  "stripeCustomerId" TEXT,
  "name" TEXT NOT NULL,
  "slug" TEXT NOT NULL UNIQUE,
  "logo" TEXT,
  "createdAt" DATE NOT NULL,
  "metadata" TEXT
);

CREATE TABLE "member" (
  "id" TEXT PRIMARY KEY NOT NULL,
  "organizationId" TEXT NOT NULL REFERENCES "organization" ("id") ON DELETE CASCADE,
  "userId" TEXT NOT NULL REFERENCES "user" ("id") ON DELETE CASCADE,
  "role" TEXT NOT NULL DEFAULT 'member',
  "createdAt" DATE NOT NULL
);

CREATE TABLE "invitation" (
  "id" TEXT PRIMARY KEY NOT NULL,
  "organizationId" TEXT NOT NULL REFERENCES "organization" ("id") ON DELETE CASCADE,
  "email" TEXT NOT NULL,
  "role" TEXT,
  "status" TEXT NOT NULL DEFAULT 'pending',
  "expiresAt" DATE NOT NULL,
  "createdAt" DATE NOT NULL,
  "inviterId" TEXT NOT NULL REFERENCES "user" ("id") ON DELETE CASCADE
);

CREATE TABLE "subscription" (
  "id" TEXT PRIMARY KEY NOT NULL,
  "plan" TEXT NOT NULL,
  "referenceId" TEXT NOT NULL,
  "stripeCustomerId" TEXT,
  "stripeSubscriptionId" TEXT,
  "status" TEXT DEFAULT 'incomplete',
  "periodStart" DATE,
  "periodEnd" DATE,
  "trialStart" DATE,
  "trialEnd" DATE,
  "cancelAtPeriodEnd" INTEGER DEFAULT 0,
  "cancelAt" DATE,
  "canceledAt" DATE,
  "endedAt" DATE,
  "seats" INTEGER,
  "billingInterval" TEXT,
  "stripeScheduleId" TEXT
);

CREATE UNIQUE INDEX "organization_slug_uidx" ON "organization" ("slug");
CREATE INDEX "member_organizationId_idx" ON "member" ("organizationId");
CREATE UNIQUE INDEX "member_userId_uidx" ON "member" ("userId");
CREATE INDEX "invitation_organizationId_idx" ON "invitation" ("organizationId");
CREATE INDEX "invitation_email_idx" ON "invitation" ("email");
CREATE INDEX "subscription_referenceId_idx" ON "subscription" ("referenceId");
