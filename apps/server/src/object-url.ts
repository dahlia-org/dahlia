import { decodeId, idPrefixes } from "./typeid";

const objectKinds = ["workspace", "project", "meeting", "file"] as const;
export type ObjectKind = typeof objectKinds[number];
export type ObjectRoute = { kind: ObjectKind; id: string };

export function objectPath(id: string): string {
  return `/o/${encodeURIComponent(id)}`;
}

export function parseObjectPath(path: string): ObjectRoute | undefined {
  const match = /^\/o\/([^/]+)$/.exec(path);
  if (!match) return;
  const id = match[1]!;
  const kind = objectKinds.find((kind) => id.startsWith(`${idPrefixes[kind]}_`));
  if (!kind) return;
  try { decodeId(kind, id); return { kind, id }; } catch { return; }
}

export function legacyObjectPath(path: string): string | undefined {
  const match = /^\/(workspaces|projects|meetings|files)\/([^/]+)$/.exec(path);
  if (!match) return;
  const target = objectPath(match[2]!);
  const object = parseObjectPath(target);
  return object && `${object.kind}s` === match[1] ? target : undefined;
}
