// Deterministic, synthetic examples only. No deployment or user data enters the published contract.
const object = (value: unknown): Record<string, unknown> => value !== null && typeof value === "object" && !Array.isArray(value)
  ? Object.fromEntries(Object.entries(value)) : {};

export function schemaExample(value: unknown, schemas: Record<string, unknown>, depth = 0): unknown {
  const schema = object(value);
  if (depth > 20) return null;
  if (schema.example !== undefined) return schema.example;
  if (schema.default !== undefined) return schema.default;
  if (typeof schema.$ref === "string") return schemaExample(schemas[schema.$ref.split("/").at(-1)!], schemas, depth + 1);
  if (Array.isArray(schema.enum)) return schema.enum[0];
  for (const union of [schema.oneOf, schema.anyOf]) {
    if (Array.isArray(union)) return schemaExample(union[0], schemas, depth + 1);
  }
  if (Array.isArray(schema.allOf)) return Object.assign({}, ...schema.allOf.map((part: unknown) => object(schemaExample(part, schemas, depth + 1))));
  const type: unknown = Array.isArray(schema.type) ? schema.type[0] : schema.type;
  if (type === "null") return null;
  if (type === "boolean") return false;
  if (type === "integer" || type === "number") return typeof schema.minimum === "number" ? schema.minimum : 1;
  if (type === "array") return Array.from({ length: typeof schema.minItems === "number" ? schema.minItems : 0 }, () => schemaExample(schema.items, schemas, depth + 1));
  if (type === "object" || schema.properties) {
    const required = Array.isArray(schema.required) ? schema.required : [];
    return Object.fromEntries(Object.entries(object(schema.properties)).filter(([key]) => required.includes(key))
      .map(([key, property]) => [key, schemaExample(property, schemas, depth + 1)]));
  }
  if (schema.format === "date-time") return "2026-09-09T00:00:00.000Z";
  if (schema.format === "uuid" || schema.format === "uuidv7") return "019f0d36-0520-7000-8000-000000000001";
  if (schema.format === "email") return "person@example.com";
  if (typeof schema.pattern === "string") {
    if (schema.pattern.includes("{8}") && schema.pattern.includes("{12}")) return "019f0d36-0520-7000-8000-000000000001";
    if (schema.pattern.includes("64")) return "a".repeat(64);
    if (schema.pattern.includes("[0-9]") || schema.pattern.includes("\\d")) return "1";
    if (schema.pattern.includes("\\/")) return "application/octet-stream";
  }
  return "example";
}
