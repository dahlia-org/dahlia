// Notion-style memory types; the agent picks one per memory, and the API and MCP tools can filter by it.
export const MEMORY_TYPES = ["profile", "preference", "work", "people", "notes"] as const;
export type MemoryType = typeof MEMORY_TYPES[number];
