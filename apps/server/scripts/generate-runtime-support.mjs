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
    for (const [capability, roles] of [['read', "'admin', 'editor', 'viewer'"], ['write', "'admin', 'editor'"], ['admin', "'admin'"]]) {
      stmts.push(`CREATE FUNCTION app.current_identity_can_${capability}_workspace(target_workspace_id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
        SELECT EXISTS (SELECT 1 FROM app.workspace_permissions p WHERE p.workspace_id = target_workspace_id AND p.role IN (${roles}) AND (
          (p.principal_type = 'user' AND p.principal_id = nullif(current_setting('app.user_id', true), '')::uuid)
          OR (p.principal_type = 'organization' AND EXISTS (SELECT 1 FROM auth.member m WHERE m.organization_id = p.principal_id AND m.user_id = nullif(current_setting('app.user_id', true), '')::uuid))
          OR (p.principal_type = 'team' AND EXISTS (SELECT 1 FROM auth.team_member tm JOIN auth.team t ON t.id = tm.team_id JOIN auth.member m ON m.organization_id = t.organization_id AND m.user_id = tm.user_id
            WHERE tm.team_id = p.principal_id AND tm.user_id = nullif(current_setting('app.user_id', true), '')::uuid)))); $$;`);
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
