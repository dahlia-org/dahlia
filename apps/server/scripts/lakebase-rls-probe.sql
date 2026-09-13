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
  WHERE pg_namespace.nspname = 'app' AND pg_class.relname = 'workspace_permissions';
  IF permission_rls IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'app.workspace_permissions must remain outside RLS';
  END IF;
END $$;

BEGIN;
SELECT set_config('app.user_id', '00000000-0000-7000-8000-000000005804', true);
SELECT set_config('app.sharing_enabled', 'true', true);

INSERT INTO auth.user (id, name, email, email_verified)
VALUES
  ('00000000-0000-7000-8000-000000005804', 'RLS probe owner', 'rls-probe-owner@invalid.example', true),
  ('00000000-0000-7000-8000-000000005800', 'RLS probe member', 'rls-probe-direct-member@invalid.example', true);
INSERT INTO auth.organization (id, name, slug, created_at)
VALUES ('00000000-0000-7000-8000-000000005899', 'Probe owner organization', 'rls-probe-owner-organization', now());
INSERT INTO auth.member (id, organization_id, user_id, role, created_at)
VALUES ('00000000-0000-7000-8000-000000005898', '00000000-0000-7000-8000-000000005899', '00000000-0000-7000-8000-000000005804', 'owner', now());
INSERT INTO app.workspaces (workspace_id, organization_id, created_by, name)
VALUES ('00000000-0000-0000-0000-000000005900', '00000000-0000-7000-8000-000000005899',
  '{"id":"00000000-0000-7000-8000-000000005804","name":"RLS probe owner","email":"rls-probe-owner@invalid.example"}', 'RLS probe');
INSERT INTO app.workspace_permissions
  (workspace_id, principal_type, principal_id, role, granted_by_user_id)
VALUES
  ('00000000-0000-0000-0000-000000005900', 'user', '00000000-0000-7000-8000-000000005804', 'admin', '00000000-0000-7000-8000-000000005804'),
  ('00000000-0000-0000-0000-000000005900', 'user', '00000000-0000-7000-8000-000000005800', 'viewer', '00000000-0000-7000-8000-000000005804'),
  ('00000000-0000-0000-0000-000000005900', 'organization', '00000000-0000-7000-8000-000000005802', 'viewer', '00000000-0000-7000-8000-000000005804'),
  ('00000000-0000-0000-0000-000000005900', 'team', '00000000-0000-7000-8000-000000005805', 'viewer', '00000000-0000-7000-8000-000000005804');
INSERT INTO app.meetings
  (meeting_id, workspace_id, name, status, created_at, updated_at)
VALUES
  ('00000000-0000-0000-0000-000000005901', '00000000-0000-0000-0000-000000005900', 'RLS probe', 'READY', now(), now());

DO $$
BEGIN
  IF (SELECT count(*) FROM app.meetings WHERE workspace_id = '00000000-0000-0000-0000-000000005900') <> 1 THEN
    RAISE EXCEPTION 'Workspace owner cannot read content through FORCE RLS';
  END IF;
END $$;

SELECT set_config('app.user_id', '00000000-0000-7000-8000-000000005800', true);
DO $$
DECLARE affected integer;
BEGIN
  IF (SELECT count(*) FROM app.meetings WHERE workspace_id = '00000000-0000-0000-0000-000000005900') <> 1 THEN
    RAISE EXCEPTION 'Direct user member cannot read shared content';
  END IF;
  UPDATE app.meetings SET name = 'forbidden'
  WHERE workspace_id = '00000000-0000-0000-0000-000000005900';
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected <> 0 THEN
    RAISE EXCEPTION 'Workspace member updated content';
  END IF;
END $$;

INSERT INTO auth.user (id, name, email, email_verified)
VALUES ('00000000-0000-7000-8000-000000005803', 'RLS probe', 'rls-probe-org-member@invalid.example', true);
INSERT INTO auth.organization (id, name, slug, created_at)
VALUES ('00000000-0000-7000-8000-000000005802', 'RLS probe', '00000000-0000-7000-8000-000000005802', now());
INSERT INTO auth.member (id, organization_id, user_id, role, created_at)
VALUES ('00000000-0000-7000-8000-000000005801', '00000000-0000-7000-8000-000000005802', '00000000-0000-7000-8000-000000005803', 'member', now());
INSERT INTO auth.team (id, name, organization_id, created_at)
VALUES ('00000000-0000-7000-8000-000000005805', 'RLS probe team', '00000000-0000-7000-8000-000000005802', now());
SELECT set_config('app.user_id', '00000000-0000-7000-8000-000000005803', true);
DO $$
BEGIN
  IF (SELECT count(*) FROM app.meetings WHERE workspace_id = '00000000-0000-0000-0000-000000005900') <> 1 THEN
    RAISE EXCEPTION 'Current organization member cannot read shared content';
  END IF;
END $$;

INSERT INTO auth.user (id, name, email, email_verified)
VALUES ('00000000-0000-7000-8000-000000005806', 'RLS probe', 'rls-probe-team-member@invalid.example', true);
INSERT INTO auth.member (id, organization_id, user_id, role, created_at)
VALUES ('00000000-0000-7000-8000-000000005808', '00000000-0000-7000-8000-000000005802', '00000000-0000-7000-8000-000000005806', 'member', now());
INSERT INTO auth.team_member (id, team_id, user_id, created_at)
VALUES ('00000000-0000-7000-8000-000000005807', '00000000-0000-7000-8000-000000005805', '00000000-0000-7000-8000-000000005806', now());
SELECT set_config('app.user_id', '00000000-0000-7000-8000-000000005806', true);
DO $$
BEGIN
  IF (SELECT count(*) FROM app.meetings WHERE workspace_id = '00000000-0000-0000-0000-000000005900') <> 1 THEN
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
