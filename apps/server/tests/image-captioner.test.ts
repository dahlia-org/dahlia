import { describe, expect, it, vi } from "vitest";
import { loadConfig } from "../src/config";
import { DEFAULT_ACCOUNT_SETTINGS } from "../src/account-settings";
import { createImageCaptioner } from "../src/image-analysis/captioner";
import { fileMetadataLimits } from "../src/files/model";

const environment = { DAHLIA_AUTH_SECRET: "test-better-auth-secret-at-least-32-characters",
  DAHLIA_AUTH_TYPE: "header", DAHLIA_AI_BACKEND: "databricks",
  DATABRICKS_HOST: "https://workspace.example", DATABRICKS_CLIENT_ID: "client", DATABRICKS_CLIENT_SECRET: "secret",
  DATABRICKS_MODEL_SCHEMA: "catalog.ai", DAHLIA_CAPTIONING_MODEL: "catalog.ai.gpt-5-6-luna",
};

describe("server image captioning", () => {
  it("uses the configured model and App SP without persisting Responses content", async () => {
    const transport = vi.fn(async (url: RequestInfo | URL, init?: RequestInit) => {
      if (String(url).endsWith("/token")) return Response.json({ access_token: "app-token", expires_in: 3600 });
      expect(String(url)).toBe("https://workspace.example/ai-gateway/mlflow/v1/responses");
      expect(init?.headers).toMatchObject({ authorization: "Bearer app-token" });
      const body = JSON.parse(String(init?.body)) as {
        instructions: string;
        input: { content: { image_url: string }[] }[];
        text: { format: { schema: { properties: { ocr_text: { maxLength: number }; caption: { maxLength: number } } } } };
      };
      expect(body).toMatchObject({ model: "catalog.ai.gpt-5-6-luna", store: false, stream: false });
      expect(body.instructions).toContain("language en");
      expect(body.input[0]?.content[0]?.image_url).toBe("data:image/webp;base64,AQID");
      expect(body.text.format.schema.properties).toMatchObject({
        ocr_text: { maxLength: fileMetadataLimits.api.ocrText },
        caption: { maxLength: fileMetadataLimits.api.caption },
      });
      return Response.json({ status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: JSON.stringify({ ocr_text: "", caption: "A diagram" }) }] }] });
    });
    const captioner = createImageCaptioner(loadConfig(environment), transport)!;
    expect(await captioner.analyze(new Uint8Array([1, 2, 3]), { ...DEFAULT_ACCOUNT_SETTINGS, outputLanguage: "en" }))
      .toEqual({ ocr_text: "", caption: "A diagram" });
  });

  it.each([429, 503, 400, 403])("classifies HTTP %s without exposing response content", async (status) => {
    const transport = vi.fn(async (url: RequestInfo | URL) => String(url).endsWith("/token")
      ? Response.json({ access_token: "app-token", expires_in: 3600 }) : new Response("private response", { status }));
    await expect(createImageCaptioner(loadConfig(environment), transport)!.analyze(new Uint8Array(), DEFAULT_ACCOUNT_SETTINGS))
      .rejects.toMatchObject({ code: `captioning_http_${status}`, retryable: status === 429 || status >= 500 });
  });

  it.each([{}, { status: "incomplete", output: [] }, { status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: '{"ocr_text":"","caption":""}' }] }] }])("rejects malformed, truncated and empty captions", async (body) => {
    const transport = vi.fn(async (url: RequestInfo | URL) => String(url).endsWith("/token")
      ? Response.json({ access_token: "app-token", expires_in: 3600 }) : Response.json(body));
    await expect(createImageCaptioner(loadConfig(environment), transport)!.analyze(new Uint8Array(), DEFAULT_ACCOUNT_SETTINGS))
      .rejects.toMatchObject({ code: "captioning_invalid_response" });
  });

  it("disables an unset model and validates its backend", () => {
    expect(createImageCaptioner(loadConfig({ ...environment, DAHLIA_CAPTIONING_MODEL: " " }))).toBeUndefined();
    expect(() => loadConfig({ DAHLIA_AUTH_SECRET: "test-better-auth-secret-at-least-32-characters", DAHLIA_AUTH_TYPE: "header", DAHLIA_CAPTIONING_MODEL: "model" })).toThrow("requires DAHLIA_AI_BACKEND=databricks");
  });
});
