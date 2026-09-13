export const idPrefixes = {
  workspace: "ws", project: "proj", meeting: "mtg", file: "file", attachment: "att",
  summary: "sum", transcript: "transcript", segment: "seg", recording: "rec",
  event: "evt", summaryJob: "sjob", contact: "contact", topic: "topic", insight: "inst",
  projectReference: "prr", user: "user", organization: "org", team: "team",
  organizationMember: "omem", teamMember: "tmem", invitation: "inv", session: "sess",
  transaction: "txn", operation: "op", patch: "patch",
} as const;

export type IDKind = keyof typeof idPrefixes;
const alphabet = "0123456789abcdefghjkmnpqrstvwxyz";
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function encodeId(kind: IDKind, uuid: string): string {
  if (!uuidPattern.test(uuid)) throw new Error("invalid_uuid");
  let value = BigInt(`0x${uuid.replaceAll("-", "")}`);
  let suffix = "";
  for (let index = 0; index < 26; index += 1) {
    suffix = alphabet[Number(value & 31n)] + suffix;
    value >>= 5n;
  }
  return `${idPrefixes[kind]}_${suffix}`;
}

export function decodeId(kind: IDKind, id: string): string {
  const prefix = `${idPrefixes[kind]}_`;
  if (!id.startsWith(prefix)) throw new Error("invalid_typeid");
  const suffix = id.slice(prefix.length);
  if (!/^[0-7][0-9abcdefghjkmnpqrstvwxyz]{25}$/.test(suffix)) throw new Error("invalid_typeid");
  let value = 0n;
  for (const character of suffix) value = (value << 5n) | BigInt(alphabet.indexOf(character));
  const hex = value.toString(16).padStart(32, "0");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
