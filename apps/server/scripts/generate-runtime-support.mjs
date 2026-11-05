import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { PgDialect, getTableConfig, PgTable } from "drizzle-orm/pg-core";
import { is } from "drizzle-orm";
import * as schema from "../src/db/postgres-app-schema.ts";

// Drizzle owns tables and policies; runtime SQL only supplies RLS functions and search indexes.
const breakpoint = "\n--> statement-breakpoint\n";
for (const dialect of ["postgres", "sqlite"]) {
  const pg = dialect === "postgres";
  const stmts = [];
  if (pg) {
    // Policies call this through an uncorrelated scalar subquery, so it runs once per statement (an InitPlan), not once per row.
    stmts.push(`CREATE FUNCTION app.current_identity_workspace_ids(capability text) RETURNS uuid[] LANGUAGE sql STABLE AS $$
        WITH me AS (SELECT nullif(current_setting('app.user_id', true), '')::uuid AS id),
        principals AS (
          SELECT 'user'::text AS type, me.id FROM me
          UNION ALL SELECT 'organization', m.organization_id FROM auth.member m, me WHERE m.user_id = me.id
          UNION ALL SELECT 'team', tm.team_id FROM auth.team_member tm JOIN auth.team t ON t.id = tm.team_id
            JOIN auth.member m ON m.organization_id = t.organization_id AND m.user_id = tm.user_id, me WHERE tm.user_id = me.id)
        SELECT coalesce(array_agg(DISTINCT p.workspace_id), '{}') FROM app.workspace_permissions p
        JOIN principals ON principals.type = p.principal_type AND principals.id = p.principal_id
        JOIN app.workspaces w ON w.workspace_id = p.workspace_id, me
        WHERE p.role = ANY (CASE capability WHEN 'admin' THEN ARRAY['admin'] WHEN 'write' THEN ARRAY['admin', 'editor'] ELSE ARRAY['admin', 'editor', 'viewer'] END)
        AND (w.personal_user_id IS NULL OR (w.personal_user_id = me.id
          AND EXISTS (SELECT 1 FROM auth.member m WHERE m.organization_id = w.organization_id AND m.user_id = w.personal_user_id))); $$;`);
    for (const capability of ['read', 'write', 'admin']) {
      stmts.push(`CREATE FUNCTION app.current_identity_can_${capability}_workspace(target_workspace_id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
        SELECT target_workspace_id = ANY (app.current_identity_workspace_ids('${capability}')); $$;`);
    }
  }
  const directory = `drizzle/${dialect}`;
  const initial = readdirSync(directory).find((name) => name.endsWith('_initial'));
  const initialPath = join(directory, initial, 'migration.sql');
  let initialSql = readFileSync(initialPath, 'utf8');
  const policies = pg ? Object.values(schema).filter((table) => is(table, PgTable)).flatMap((table) => {
    const config = getTableConfig(table);
    return config.policies.map((policy) => {
      const render = (expression) => new PgDialect().sqlToQuery(expression).sql;
      return `CREATE POLICY "${policy.name}" ON "${config.schema}"."${config.name}" FOR ${policy.for.toUpperCase()}${policy.using ? ` USING (${render(policy.using)})` : ''}${policy.withCheck ? ` WITH CHECK (${render(policy.withCheck)})` : ''};`;
    });
  }) : [];
  initialSql = initialSql.replace(/CREATE POLICY[^;]+;(?:\s*--> statement-breakpoint)?/g, '');
  writeFileSync(initialPath, initialSql.replace(/[\t ]+$/gm, '').trim() + '\n');
  const runtimePath = join(directory, '20260912180000_runtime_support/migration.sql');
  const base = readFileSync(`scripts/runtime-support/${dialect}.sql`, 'utf8').trimEnd();
  writeFileSync(runtimePath, [...stmts, base, ...policies].join(breakpoint) + '\n');
}
