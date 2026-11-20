import { join } from "node:path";
import { describe, expect, it } from "vitest";
import * as policy from "../src/main/policy.js";

describe("policy", () => {
  it("trusts only the app's own pages", () => {
    expect(policy.isAppUrl("app://dahlia/index.html")).toBe(true);
    expect(policy.isAppUrl("app://other/")).toBe(false);
    expect(policy.isAppUrl("https://dahlia/")).toBe(false);
    expect(policy.isAppUrl("http://localhost:5175/", "http://localhost:5175")).toBe(true);
    expect(policy.isAppUrl("http://localhost:5175/")).toBe(false);
    expect(policy.isAppUrl("not a url")).toBe(false);
  });

  it("accepts only UUIDs, known sources and bounded names", () => {
    expect(policy.id("0192f6a0-1c2b-7d3e-8f40-123456789abc")).toBe("0192f6a0-1c2b-7d3e-8f40-123456789abc");
    expect(() => policy.id("../etc")).toThrow();
    expect(policy.source("system")).toBe("system");
    expect(() => policy.source("camera")).toThrow();
    expect(policy.meetingName("  Weekly  ")).toBe("Weekly");
    expect(() => policy.meetingName(" ")).toThrow();
    expect(() => policy.meetingName("x".repeat(201))).toThrow();
  });

  it("accepts only known settings with plausible values", () => {
    expect(policy.settingsPatch({ transcriptionLocale: "en-US", summaryLanguage: "ja", summaryModel: "system.ai.claude-opus-5-5" }))
      .toEqual({ transcriptionLocale: "en-US", summaryLanguage: "ja", summaryModel: "system.ai.claude-opus-5-5" });
    expect(() => policy.settingsPatch({ summaryModel: "system.ai.gpt-6" })).toThrow();
    expect(() => policy.settingsPatch({ summaryLanguage: "xx" })).toThrow();
    expect(() => policy.settingsPatch({ other: "x" })).toThrow();
    expect(() => policy.settingsPatch(null)).toThrow();
  });

  it("serves only files under the renderer root, and the app for history routes", () => {
    expect(policy.rendererFile("/r", "/assets/a.js", join)).toBe("/r/assets/a.js");
    expect(policy.rendererFile("/r", "/meetings/1", join)).toBe("/r/index.html");
    expect(policy.rendererFile("/r", "/../../etc/passwd", join)).toBe("/r/index.html");
    expect(policy.rendererFile("/r", "/%2e%2e/secret.txt", join)).toBe("/r/index.html");
  });
});
