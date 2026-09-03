\set ON_ERROR_STOP on

DO $$
DECLARE role_row record;
DECLARE permission_rls boolean;
BEGIN
  SELECT rolsuper, rolbypassrls INTO role_row FROM pg_roles WHERE rolname = current_user;
  IF role_row.rolsuper OR role_row.rolbypassrls THEN
    RAISE EXCEPTION 'Dahlia sync requires a non-superuser NOBYPASSRLS role';
  END IF;
  SELECT relrowsecurity INTO permission_rls
  FROM pg_class JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
  WHERE pg_namespace.nspname = 'core' AND pg_class.relname = 'vault_permissions';
  IF permission_rls IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'core.vault_permissions must remain outside RLS';
  END IF;
END $$;

BEGIN;
SELECT set_config('app.user_id', 'rls-probe-owner', true);

INSERT INTO auth.user (id, name, email, email_verified)
VALUES
  ('rls-probe-owner', 'RLS probe owner', 'rls-probe-owner@invalid.example', true),
  ('rls-probe-direct-member', 'RLS probe member', 'rls-probe-direct-member@invalid.example', true);
INSERT INTO core.vaults (vault_id)
VALUES ('00000000-0000-0000-0000-000000005900');
INSERT INTO core.vault_permissions
  (vault_id, principal_type, principal_id, role, granted_by_user_id)
VALUES
  ('00000000-0000-0000-0000-000000005900', 'user', 'rls-probe-owner', 'owner', 'rls-probe-owner'),
  ('00000000-0000-0000-0000-000000005900', 'user', 'rls-probe-direct-member', 'member', 'rls-probe-owner'),
  ('00000000-0000-0000-0000-000000005900', 'organization', 'rls-probe-org', 'member', 'rls-probe-owner'),
  ('00000000-0000-0000-0000-000000005900', 'team', 'rls-probe-team', 'member', 'rls-probe-owner');
INSERT INTO content.meetings
  (meeting_id, vault_id, name, status, created_at, updated_at)
VALUES
  ('00000000-0000-0000-0000-000000005901', '00000000-0000-0000-0000-000000005900', 'RLS probe', 'READY', now(), now());

DO $$
BEGIN
  IF (SELECT count(*) FROM content.meetings WHERE vault_id = '00000000-0000-0000-0000-000000005900') <> 1 THEN
    RAISE EXCEPTION 'Vault owner cannot read content through FORCE RLS';
  END IF;
END $$;

SELECT set_config('app.user_id', 'rls-probe-direct-member', true);
DO $$
DECLARE affected integer;
BEGIN
  IF (SELECT count(*) FROM content.meetings WHERE vault_id = '00000000-0000-0000-0000-000000005900') <> 1 THEN
    RAISE EXCEPTION 'Direct user member cannot read shared content';
  END IF;
  UPDATE content.meetings SET name = 'forbidden'
  WHERE vault_id = '00000000-0000-0000-0000-000000005900';
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected <> 0 THEN
    RAISE EXCEPTION 'Vault member updated content';
  END IF;
END $$;

INSERT INTO auth.user (id, name, email, email_verified)
VALUES ('rls-probe-org-member', 'RLS probe', 'rls-probe-org-member@invalid.example', true);
INSERT INTO auth.organization (id, name, slug, created_at)
VALUES ('rls-probe-org', 'RLS probe', 'rls-probe-org', now());
INSERT INTO auth.member (id, organization_id, user_id, role, created_at)
VALUES ('rls-probe-membership', 'rls-probe-org', 'rls-probe-org-member', 'member', now());
INSERT INTO auth.team (id, name, organization_id, created_at)
VALUES ('rls-probe-team', 'RLS probe team', 'rls-probe-org', now());
SELECT set_config('app.user_id', 'rls-probe-org-member', true);
DO $$
BEGIN
  IF (SELECT count(*) FROM content.meetings WHERE vault_id = '00000000-0000-0000-0000-000000005900') <> 1 THEN
    RAISE EXCEPTION 'Current organization member cannot read shared content';
  END IF;
END $$;

INSERT INTO auth.user (id, name, email, email_verified)
VALUES ('rls-probe-team-member', 'RLS probe', 'rls-probe-team-member@invalid.example', true);
INSERT INTO auth.member (id, organization_id, user_id, role, created_at)
VALUES ('rls-probe-team-membership', 'rls-probe-org', 'rls-probe-team-member', 'member', now());
INSERT INTO auth.team_member (id, team_id, user_id, created_at)
VALUES ('rls-probe-team-member-row', 'rls-probe-team', 'rls-probe-team-member', now());
SELECT set_config('app.user_id', 'rls-probe-team-member', true);
DO $$
BEGIN
  IF (SELECT count(*) FROM content.meetings WHERE vault_id = '00000000-0000-0000-0000-000000005900') <> 1 THEN
    RAISE EXCEPTION 'Team member cannot read shared content';
  END IF;
END $$;

ROLLBACK;

DO $$
BEGIN
  IF coalesce(current_setting('app.user_id', true), '') <> '' THEN
    RAISE EXCEPTION 'transaction-local identity context leaked after rollback';
  END IF;
END $$;

BEGIN;
SELECT set_config('app.user_id', 'commit-probe', true);
COMMIT;
DO $$
BEGIN
  IF coalesce(current_setting('app.user_id', true), '') <> '' THEN
    RAISE EXCEPTION 'transaction-local identity context leaked after commit';
  END IF;
END $$;
