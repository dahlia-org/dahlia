import type { OpenAPIHono } from "@hono/zod-openapi";
import contract from "../public-id-contract.json";
import { entityKinds, publicRoute, recordShapes } from "../public-wire";
import { idPrefixes, type IDKind } from "../typeid";

type Schema = Record<string, unknown>;
const object = (value: unknown): value is Schema => typeof value === "object" && value !== null && !Array.isArray(value);
const shapes: Record<string, Record<string, string>> = contract.shapes;

/** Publish the same ID fields the HTTP adapter encodes; internal Zod validation remains UUID-based. */
export function projectPublicIDs(document: ReturnType<OpenAPIHono["getOpenAPI31Document"]>): void {
  const visited = new WeakMap<Schema, Set<string>>();
  const kinds = new WeakMap<Schema, Set<IDKind>>();
  const uuidV7 = new WeakSet<Schema>();
  function resolve(value: unknown): Schema | undefined {
    if (!object(value)) return;
    if (typeof value.$ref !== "string") return value;
    let target: unknown = document;
    for (const key of value.$ref.slice(2).split("/")) {
      target = object(target) ? target[key] : undefined;
    }
    return object(target) ? target : undefined;
  }
  function id(schema: Schema, choices: IDKind[]) {
    const current = kinds.get(schema) ?? new Set<IDKind>();
    for (const kind of choices) current.add(kind);
    kinds.set(schema, current);
    const prefixes = [...current].map((kind) => idPrefixes[kind]).sort();
    const prefix = prefixes.length === 1 ? prefixes[0] : `(${prefixes.join("|")})`;
    if (schema.format === "uuidv7") uuidV7.add(schema);
    delete schema.format;
    // Base32 positions 10 and 13 retain the UUID version 7 and RFC variant bits.
    const suffix = uuidV7.has(schema)
      ? "[0-7][0-9abcdefghjkmnpqrstvwxyz]{9}[ef][0-9abcdefghjkmnpqrstvwxyz]{2}[89abrstv][0-9abcdefghjkmnpqrstvwxyz]{12}"
      : "[0-7][0-9abcdefghjkmnpqrstvwxyz]{25}";
    schema.pattern = `^${prefix}_${suffix}$`;
  }
  function visit(value: unknown, shape: string) {
    const schema = resolve(value);
    if (!schema) return;
    const seen = visited.get(schema) ?? new Set<string>();
    if (seen.has(shape)) return;
    seen.add(shape);
    visited.set(schema, seen);
    if (shape.startsWith("id:")) {
      id(schema, [shape.slice(3) as IDKind]);
      return;
    }
    for (const key of ["anyOf", "oneOf", "allOf"]) {
      const variants = schema[key];
      if (Array.isArray(variants)) for (const variant of variants) visit(variant, shape);
    }
    if (shape.startsWith("array:")) {
      visit(schema.items, shape.slice(6));
      return;
    }
    if (shape === "personalWorkspace") {
      schema.pattern = "^personal:user_[0-7][0-9abcdefghjkmnpqrstvwxyz]{25}$";
      return;
    }
    // Cursors, URLs and serialized documents retain their opaque string schemas.
    if (!object(schema.properties)) return;
    const properties = schema.properties;
    if (shape === "canonical" || shape === "operation") {
      const entity = resolve(properties.entity)?.enum;
      if (!Array.isArray(entity)) return;
      const names = entity.map(String);
      const entityID = resolve(properties.entityId);
      const recordID = resolve(properties.id);
      if (entityID) id(entityID, names.map((name) => entityKinds[name]!));
      if (recordID) id(recordID, shape === "operation" ? ["operation"] : names.map((name) => entityKinds[name]!));
      for (const [field, kind] of Object.entries({ vaultId: "vault", transactionId: "transaction", operationId: "operation" })) visit(properties[field], `id:${kind}`);
      for (const name of names) for (const field of ["data", "record"]) visit(properties[field], recordShapes[name]!);
      return;
    }
    if (shape === "permission") {
      const principal = resolve(properties.principalId);
      if (principal) id(principal, ["user", "organization", "team"]);
      visit(properties.vaultId, "id:vault");
      visit(properties.grantedByUserId, "id:user");
      return;
    }
    if (shape === "textSearchHit") {
      const hit = resolve(properties.id);
      if (hit) id(hit, ["meeting", "attachment"]);
      visit(properties.meetingId, "id:meeting");
      return;
    }
    for (const [field, fieldShape] of Object.entries(shapes[shape] ?? {})) visit(properties[field], fieldShape);
    if (shape === "event" && (resolve(properties.kind)?.enum as unknown[] | undefined)?.includes("segment_rotated")) {
      visit(properties.relatedId, "id:segment");
    }
  }
  function content(value: unknown, shape: string | undefined) {
    const body = resolve(value);
    if (!shape || !body || !object(body.content)) return;
    for (const [type, media] of Object.entries(body.content)) {
      if (type.includes("json") && object(media)) visit(media.schema, shape);
    }
  }
  for (const [path, item] of Object.entries(document.paths ?? {})) {
    for (const [method, value] of Object.entries(item ?? {})) {
      if (!object(value) || typeof value.operationId !== "string") continue;
      const route = publicRoute(path, method.toUpperCase());
      if (!route) continue;
      const parameters = Array.isArray(value.parameters) ? value.parameters : [];
      for (const value of parameters) {
        const parameter = resolve(value);
        if (!parameter || typeof parameter.name !== "string") continue;
        if (parameter.in === "path") {
          const index = path.split("/").indexOf(`{${parameter.name}}`);
          const kind = route.path.split("/")[index]?.slice(1);
          if (kind && Object.hasOwn(idPrefixes, kind)) visit(parameter.schema, `id:${kind}`);
        } else {
          const shape = parameter.in === "query" ? route.query?.[parameter.name] : route.headers?.[parameter.name.toLowerCase()];
          if (shape) visit(parameter.schema, shape);
        }
      }
      content(value.requestBody, route.request);
      if (object(value.responses)) for (const [status, response] of Object.entries(value.responses)) {
        content(response, status === "default" || Number(status) >= 400 ? "error" : route.response);
      }
    }
  }
}
