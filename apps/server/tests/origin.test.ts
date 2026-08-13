import { describe, expect, it } from "vitest";

import { mutationOriginAllowed } from "../src/app";

describe("browser mutation origin", () => {
  it("allows reads and same-origin writes", () => {
    expect(mutationOriginAllowed(new Request("https://dahlia.example/api/sessions"), "https://dahlia.example")).toBe(true);
    expect(
      mutationOriginAllowed(
        new Request("https://dahlia.example/api/sessions", {
          method: "POST",
          headers: { origin: "https://dahlia.example" },
        }),
        "https://dahlia.example",
      ),
    ).toBe(true);
  });

  it("rejects missing and cross-origin mutation origins", () => {
    expect(
      mutationOriginAllowed(
        new Request("https://dahlia.example/api/sessions", { method: "POST" }),
        "https://dahlia.example",
      ),
    ).toBe(false);
    expect(
      mutationOriginAllowed(
        new Request("https://dahlia.example/api/sessions", {
          method: "POST",
          headers: { origin: "https://attacker.example" },
        }),
        "https://dahlia.example",
      ),
    ).toBe(false);
  });
});
