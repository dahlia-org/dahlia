import contract from "./public-id-contract.json";
import { decodeId, encodeId, idPrefixes, type IDKind } from "./typeid";

export type WireDirection = "encode" | "decode";
type ObjectValue = Record<string, unknown>;
const shapes: Record<string, Record<string, string>> = contract.shapes;
export interface PublicRoute {
  path: string;
  response?: string;
  request?: string;
  query?: Record<string, string>;
  headers?: Record<string, string>;
  methods?: string[];
  limit?: number;
}
const routes = contract.routes as PublicRoute[];
export const entityKinds: Record<string, IDKind> = {
  vault: "vault", project: "project", meeting: "meeting", summary: "meeting", transcript: "meeting",
  file: "file", meeting_attachment: "attachment", meeting_event: "event", recording: "recording",
};
export const recordShapes: Record<string, string> = {
  ...entityKinds, summary: "summary", transcript: "transcriptPatch",
};
const resourceKinds: Record<string, IDKind> = {
  meeting: "meeting", project: "project", contact: "contact", topic: "topic", conversation_topic: "topic", insight: "insight", organization: "organization",
};
const object = (value: unknown): value is ObjectValue => value !== null && typeof value === "object" && !Array.isArray(value);

export function wireID(value: unknown, kind: IDKind, direction: WireDirection): unknown {
  if (value === null || value === undefined) return value;
  if (typeof value !== "string") throw new Error("invalid_typeid");
  return direction === "encode" ? encodeId(kind, value) : decodeId(kind, value);
}

/** Applies only the declared fields of a named wire contract. Free text and metadata are never traversed. */
export function wireValue(value: unknown, shape: string, direction: WireDirection, parent: ObjectValue = {}): unknown {
  if (value === null || value === undefined || shape === "pass") return value;
  if (shape.startsWith("id:")) return wireID(value, shape.slice(3) as IDKind, direction);
  if (shape.startsWith("array:")) {
    if (!Array.isArray(value)) throw new Error("invalid_public_shape");
    return value.map((item) => wireValue(item, shape.slice(6), direction));
  }
  if (shape.startsWith("filter:")) {
    const fieldShape = shapes[shape.slice(7)]?.[String(parent.filterField)];
    return fieldShape?.startsWith("id:") ? wireValue(value, fieldShape, direction) : value;
  }
  if (shape.startsWith("cursor:")) return wireCursor(value, shape.slice(7), direction);
  if (shape === "url") return typeof value === "string" ? wireURL(value, direction) : value;
  if (shape === "urls") return object(value) ? Object.fromEntries(Object.entries(value).map(([key, url]) => [key, wireValue(url, "url", direction)])) : value;
  if (shape === "teamList" && typeof value === "string") return value.split(",").map((id) => wireID(id, "team", direction)).join(",");
  if (shape === "teamChoice") return Array.isArray(value) ? value.map((id) => wireID(id, "team", direction)) : wireID(value, "team", direction);
  if (shape === "document") return wireDocument(value, direction);
  if (shape === "personalWorkspace") {
    if (typeof value !== "string" || !value.startsWith("personal:")) throw new Error("invalid_workspace_id");
    return `personal:${String(wireID(value.slice(9), "user", direction))}`;
  }
  if (shape === "memberOrEmail") return typeof value === "string" && value.includes("@") ? value : wireID(value, "organizationMember", direction);
  if (shape === "resourceID") {
    const resourceType = parent.resource_type ?? parent.resourceType;
    const kind = resourceKinds[String(resourceType)];
    if (kind) return wireID(value, kind, direction);
    throw new Error("invalid_resource_type");
  }
  if (shape === "textEntityID") return wireID(value, parent.entity === "file" ? "file" : "meeting", direction);
  if (shape === "relationshipSource" || shape === "relationshipTarget") {
    const kinds: Record<string, [IDKind | null, IDKind | null]> = {
      organization_domain: ["organization", null], contact_organization_membership: ["contact", "organization"],
      project_resource_reference: ["project", resourceKinds[String(parent.resource_type)] ?? null],
      conversation_topic_resource_reference: ["topic", resourceKinds[String(parent.resource_type)] ?? null],
      insight_resource_reference: ["insight", resourceKinds[String(parent.resource_type)] ?? null],
      meeting_project_assignment: ["meeting", "project"],
    };
    const kind = kinds[String(parent.relationship)]?.[shape === "relationshipSource" ? 0 : 1];
    return kind ? wireID(value, kind, direction) : value;
  }
  if (!object(value)) return value;
  if (shape === "canonical" || shape === "operation") {
    const entity = String(value.entity);
    const kind = entityKinds[entity];
    if (!kind) throw new Error("invalid_sync_entity");
    const result = { ...value };
    for (const key of ["id", "entityId"]) if (key in result) {
      result[key] = wireID(result[key], key === "id" && shape === "operation" ? "operation" : kind, direction);
    }
    for (const [key, type] of Object.entries({ vaultId: "vault", transactionId: "transaction", operationId: "operation" } as const)) {
      if (key in result) result[key] = wireID(result[key], type, direction);
    }
    for (const key of ["data", "record"]) if (key in result) result[key] = wireValue(result[key], recordShapes[entity]!, direction);
    return result;
  }
  if (shape === "permission") {
    const result = { ...value };
    const kind = { user: "user", organization: "organization", team: "team" }[String(value.principalType)] as IDKind | undefined;
    if (kind && "principalId" in value) result.principalId = wireID(value.principalId, kind, direction);
    for (const [key, kind] of Object.entries({ vaultId: "vault", grantedByUserId: "user" } as const)) {
      if (key in result) result[key] = wireID(result[key], kind, direction);
    }
    return result;
  }
  if (shape === "textSearchHit") {
    const result = { ...value };
    const kind = value.kind === "screenshot" ? "attachment" : "meeting";
    for (const key of ["id", "sourceId", "source_id"]) if (key in result) result[key] = wireID(result[key], kind, direction);
    for (const key of ["meetingId", "meeting_id"]) if (key in result) result[key] = wireID(result[key], "meeting", direction);
    return result;
  }
  const fields = shapes[shape];
  if (!fields) throw new Error(`Unknown public ID shape: ${shape}`);
  const result = { ...value };
  for (const [key, fieldShape] of Object.entries(fields)) {
    if (key in value) result[key] = wireValue(value[key], fieldShape, direction, value);
  }
  if (shape === "event" && value.kind === "segment_rotated" && "relatedId" in value) {
    result.relatedId = wireID(value.relatedId, "segment", direction);
  }
  // Other result shapes can carry errors too; the error shape already converted these fields.
  if (shape !== "error" && "error" in value) {
    if ("conflicts" in value) result.conflicts = wireValue(value.conflicts, "array:canonical", direction);
    if ("operationId" in value) result.operationId = wireID(value.operationId, "operation", direction);
  }
  return result;
}

export function wireCursor(value: unknown, kind: string, direction: WireDirection): unknown {
  if (value === null || value === undefined) return value;
  if (typeof value !== "string") throw new Error("invalid_cursor");
  if (kind === "live") {
    const cursor: unknown = JSON.parse(atob(value));
    if (!object(cursor)) throw new Error("invalid_cursor");
    for (const [key, type] of Object.entries({ vaultId: "vault", meetingId: "meeting", sessionId: "recording", generation: "transcript" } as const)) {
      if (key === "generation" && cursor[key] === "none") continue;
      cursor[key] = wireID(cursor[key], type, direction);
    }
    return btoa(JSON.stringify(cursor));
  }
  if (kind === "textSearch") {
    const parts: unknown = JSON.parse(value);
    if (!Array.isArray(parts) || parts.length !== 5) throw new Error("invalid_cursor");
    parts[0] = wireID(parts[0], "vault", direction);
    return JSON.stringify(parts);
  }
  if (kind === "file" || kind === "attachment") return wireID(value, kind, direction);
  const parts = value.split(",");
  if (parts.length !== 2) throw new Error("invalid_cursor");
  let type: IDKind | undefined;
  switch (kind) {
    case "snapshot": type = entityKinds[parts[0]!]; break;
    case "screenshot": type = "attachment"; break;
    default: type = kind as IDKind;
  }
  if (!type) throw new Error("invalid_cursor");
  return `${parts[0]},${String(wireID(parts[1], type, direction))}`;
}

export function publicRoute(path: string, method = "GET"): PublicRoute | undefined {
  const parts = path.split("/");
  return routes.find((route) => {
    if (route.methods && !route.methods.includes(method)) return false;
    const template = route.path.split("/");
    return template.length === parts.length && template.every((part, index) => part.startsWith(":") ? !!parts[index] : part === parts[index]);
  });
}

export function wireURL(value: string, direction: WireDirection, method = "GET"): string {
  const absolute = /^[a-z][a-z0-9+.-]*:/i.test(value);
  const url = new URL(value, "https://dahlia.invalid");
  const route = publicRoute(url.pathname, method);
  if (!route) return value;
  const parts = url.pathname.split("/");
  route.path.split("/").forEach((part, index) => {
    const kind = part.slice(1);
    if (part.startsWith(":") && Object.hasOwn(idPrefixes, kind)) {
      parts[index] = String(wireID(decodeURIComponent(parts[index]!), kind as IDKind, direction));
    }
  });
  url.pathname = parts.join("/");
  const query = [...url.searchParams].map(([key, value]) => [key,
    route.query?.[key] ? String(wireValue(value, route.query[key], direction, Object.fromEntries(url.searchParams))) : value,
  ]);
  url.search = new URLSearchParams(query).toString();
  return absolute ? url.href : `${url.pathname}${url.search}${url.hash}`;
}

/** Preserve the serialized document byte-for-byte except declared image references.
 * Content digests use the restored internal representation, including original JSON whitespace. */
export function wireDocument(value: unknown, direction: WireDirection): unknown {
  const serialized = typeof value === "string";
  const source = serialized ? value : JSON.stringify(value);
  try { JSON.parse(source); } catch { return value; }
  const tokens = [...source.matchAll(/"(?:\\.|[^"\\])*"|[{}[\]:,]|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null/g)];
  let index = 0;
  const edits: { start: number; end: number; value: string }[] = [];
  function walk(path: string[]) {
    const token = tokens[index++];
    if (!token) throw new Error("invalid_document");
    if (token[0] === "{") {
      while (tokens[index]?.[0] !== "}") {
        const key = JSON.parse(tokens[index++]![0]) as string;
        index += 1; // colon, already validated by JSON.parse
        walk([...path, key]);
        if (tokens[index]?.[0] !== ",") break;
        index += 1;
      }
      index += 1;
    } else if (token[0] === "[") {
      while (tokens[index]?.[0] !== "]") {
        walk([...path, "*"]);
        if (tokens[index]?.[0] !== ",") break;
        index += 1;
      }
      index += 1;
    } else if (path.join(".") === "sections.*.blocks.*.screenshot_id" || path.join(".") === "sections.*.blocks.*.screenshotId") {
      edits.push({ start: token.index, end: token.index + token[0].length,
        value: JSON.stringify(wireID(JSON.parse(token[0]), "attachment", direction)) });
    }
  }
  walk([]);
  let output = source;
  for (const edit of edits.reverse()) output = output.slice(0, edit.start) + edit.value + output.slice(edit.end);
  return serialized ? output : JSON.parse(output);
}
