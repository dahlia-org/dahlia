import { describe, expect, it } from "vitest";
import { appOrigin, callbackPath, externalURL, isServerPath, relayAllowed, rendererFile, serverOrigin, signInCompleted } from "../src/main/policy";

describe("main process trust boundaries", () => {
  it("accepts https Servers and plain http only on loopback", () => {
    expect(serverOrigin()).toBe("http://localhost:5173");
    expect(serverOrigin("https://dahlia.example/path")).toBe("https://dahlia.example");
    expect(serverOrigin("http://127.0.0.1:3000")).toBe("http://127.0.0.1:3000");
    expect(() => serverOrigin("http://dahlia.example")).toThrow();
    expect(() => serverOrigin("https://user:secret@dahlia.example")).toThrow();
    expect(() => serverOrigin("file:///etc/passwd")).toThrow();
  });

  it("relays only API paths and only for the bundled renderer", () => {
    expect(isServerPath("/api/v1/session")).toBe(true);
    expect(isServerPath("/apiary")).toBe(false);
    expect(isServerPath("/dashboard")).toBe(false);
    expect(relayAllowed(null)).toBe(true);
    expect(relayAllowed(appOrigin)).toBe(true);
    expect(relayAllowed("https://accounts.google.com")).toBe(false);
    expect(relayAllowed("null")).toBe(false);
  });

  it("serves renderer files without leaving the renderer directory", () => {
    expect(rendererFile("/app/renderer", "/assets/index.js")).toBe("/app/renderer/assets/index.js");
    expect(rendererFile("/app/renderer", "/")).toBeUndefined();
    expect(rendererFile("/app/renderer", "/../main.js")).toBeUndefined();
    expect(rendererFile("/app/renderer", "/%2e%2e/main.js")).toBeUndefined();
    expect(rendererFile("/app/renderer", "/%E0%A4%A")).toBeUndefined();
  });

  it("completes sign-in only on a Server application page", () => {
    const server = "http://localhost:5173";
    expect(signInCompleted("http://localhost:5173/dashboard", server)).toBe(true);
    expect(signInCompleted("http://localhost:5173/sign-in?next=%2Fdashboard", server)).toBe(false);
    expect(signInCompleted("http://localhost:5173/api/auth/callback/google?code=x", server)).toBe(false);
    expect(signInCompleted("https://accounts.google.com/dashboard", server)).toBe(false);
  });

  it("keeps sign-in callbacks inside the app and opens only web links externally", () => {
    expect(callbackPath("/o/mtg_123")).toBe("/o/mtg_123");
    expect(callbackPath("//evil.example")).toBe("/dashboard");
    expect(callbackPath("https://evil.example")).toBe("/dashboard");
    expect(callbackPath(42)).toBe("/dashboard");
    const server = "https://dahlia.example";
    expect(externalURL("app://dahlia/o/mtg_1?x=1#a", server)).toBe("https://dahlia.example/o/mtg_1?x=1#a");
    expect(externalURL("https://docs.example/a", server)).toBe("https://docs.example/a");
    expect(externalURL("file:///etc/passwd", server)).toBeUndefined();
    expect(externalURL("javascript:alert(1)", server)).toBeUndefined();
  });
});
