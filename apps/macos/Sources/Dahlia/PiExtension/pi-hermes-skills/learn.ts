// Hermes `/learn` (agent/learn_prompt.py) as a Pi prompt template, so it is listed with the chat's commands.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const learnTemplatePath = fileURLToPath(new URL("./prompts/learn.md", import.meta.url));

export interface LearnOptions {
  /** The skill's `author`, and the name its instructions use for the agent. */
  agent?: string;
  /** Tools the skill may name, in this order. */
  tools?: string[];
}

// Pi splits template arguments into words and rejoins them with spaces, which would flatten pasted notes.
// Upstream inserts the request verbatim, so expand `/learn` before Pi does.
export function registerLearn(pi: any, options: LearnOptions = {}) {
  const tools = (options.tools ?? ["bash", "read", "ls", "write", "edit", "skill_view", "skill_manage"]).map((name) => `\`${name}\``);
  const template = readFileSync(learnTemplatePath, "utf8").replace(/^---\n[\s\S]*?\n---\n/, "")
    .replaceAll("{{agent}}", options.agent ?? "Pi").replace("{{tools}}", tools.join(", "));
  pi.on("input", (event: any) => {
    const match = /^\/learn(?:\s+([\s\S]*))?$/.exec(event.text);
    if (match) return { action: "transform", text: expandLearn(template, match[1] ?? "") };
  });
}

// An empty request means "the workflow we just went through", upstream's default.
export const expandLearn = (template: string, request: string) =>
  template.replace(/\$\{@:-([^}]*)\}/, (_match, fallback) => request.trim() || fallback);
