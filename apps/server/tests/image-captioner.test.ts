import { describe, expect, it, vi } from "vitest";
import { loadConfig } from "../src/config";
import { createImageCaptioner } from "../src/image-analysis/captioner";
import { fileMetadataLimits } from "../src/files/model";
import { IMAGE_ANALYSIS_REASON_LIMIT } from "../src/image-analysis/model";

const environment = { DAHLIA_AUTH_SECRET: "test-better-auth-secret-at-least-32-characters",
  DAHLIA_AUTH_TYPE: "header", DAHLIA_AI_BACKEND: "databricks",
  DATABRICKS_HOST: "https://workspace.example", DATABRICKS_CLIENT_ID: "client", DATABRICKS_CLIENT_SECRET: "secret",
  DAHLIA_IMAGE_ANALYSIS_MODEL: "system.ai.gpt-5-6-luna",
};

describe("server image captioning", () => {
  it("uses the configured model and App SP without persisting Responses content", async () => {
    const analysis = { ocr_text: "", caption: "A diagram", informative: true, reason: "An architecture diagram", same_as_previous: false };
    const transport = vi.fn(async (url: RequestInfo | URL, init?: RequestInit) => {
      if (String(url).endsWith("/token")) return Response.json({ access_token: "app-token", expires_in: 3600 });
      expect(String(url)).toBe("https://workspace.example/ai-gateway/mlflow/v1/responses");
      expect(init?.headers).toMatchObject({ authorization: "Bearer app-token" });
      const body = JSON.parse(String(init?.body)) as {
        instructions: string;
        input: { content: { type: string; text?: string; image_url?: string }[] }[];
        text: { format: { schema: { properties: { images: { items: { properties: Record<string, { maxLength?: number }> } } } } } };
      };
      expect(body).toMatchObject({ model: "system.ai.gpt-5-6-luna", store: false, stream: false });
      expect(body.instructions).toContain("language en");
      expect(body.input[0]?.content).toEqual([
        { type: "input_text", text: '<image index="1" role="reference"/>' },
        { type: "input_image", image_url: "data:image/webp;base64,BAU=" },
        { type: "input_text", text: '<image index="2" role="target"/>' },
        { type: "input_image", image_url: "data:image/webp;base64,AQID" },
      ]);
      expect(body.text.format.schema.properties.images.items.properties).toMatchObject({
        ocr_text: { maxLength: fileMetadataLimits.api.ocrText },
        caption: { maxLength: fileMetadataLimits.api.caption },
        reason: { maxLength: IMAGE_ANALYSIS_REASON_LIMIT },
      });
      return Response.json({ status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: JSON.stringify({ images: [analysis] }) }] }] });
    });
    const captioner = createImageCaptioner(loadConfig(environment), transport)!;
    expect(captioner.batchSize).toBe(12);
    expect(await captioner.analyze([{ data: new Uint8Array([4, 5]), reference: true }, { data: new Uint8Array([1, 2, 3]) }], { outputLanguage: "en" }))
      .toEqual([analysis]);
  });

  it("rejects a batch result that does not match the target images", async () => {
    const analysis = { ocr_text: "", caption: "A diagram", informative: true, reason: "A diagram", same_as_previous: false };
    const transport = vi.fn(async (url: RequestInfo | URL) => String(url).endsWith("/token")
      ? Response.json({ access_token: "app-token", expires_in: 3600 })
      : Response.json({ status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: JSON.stringify({ images: [analysis] }) }] }] }));
    await expect(createImageCaptioner(loadConfig(environment), transport)!.analyze([{ data: new Uint8Array() }, { data: new Uint8Array() }], { outputLanguage: "ja" }))
      .rejects.toMatchObject({ code: "captioning_invalid_response", retryable: false });
    expect(createImageCaptioner(loadConfig({ ...environment, DAHLIA_IMAGE_ANALYSIS_BATCH_SIZE: "3" }), transport)!.batchSize).toBe(3);
  });

  it.each([429, 503, 400, 403])("classifies HTTP %s without exposing response content", async (status) => {
    const transport = vi.fn(async (url: RequestInfo | URL) => String(url).endsWith("/token")
      ? Response.json({ access_token: "app-token", expires_in: 3600 }) : new Response("private response", { status }));
    await expect(createImageCaptioner(loadConfig(environment), transport)!.analyze([{ data: new Uint8Array() }], { outputLanguage: "ja" }))
      .rejects.toMatchObject({ code: `captioning_http_${status}`, retryable: status === 429 || status >= 500 });
  });

  it.each([{}, { status: "incomplete", output: [] }, { status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: '{"images":[{"ocr_text":"","caption":"","informative":true,"reason":"x","same_as_previous":false}]}' }] }] }])("rejects malformed, truncated and empty captions", async (body) => {
    const transport = vi.fn(async (url: RequestInfo | URL) => String(url).endsWith("/token")
      ? Response.json({ access_token: "app-token", expires_in: 3600 }) : Response.json(body));
    await expect(createImageCaptioner(loadConfig(environment), transport)!.analyze([{ data: new Uint8Array() }], { outputLanguage: "ja" }))
      .rejects.toMatchObject({ code: "captioning_invalid_response" });
  });

  it("disables an unset model and validates its backend", () => {
    expect(createImageCaptioner(loadConfig({ ...environment, DAHLIA_IMAGE_ANALYSIS_MODEL: " " }))).toBeUndefined();
    expect(() => loadConfig({ DAHLIA_AUTH_SECRET: "test-better-auth-secret-at-least-32-characters", DAHLIA_AUTH_TYPE: "header", DAHLIA_IMAGE_ANALYSIS_MODEL: "model" })).toThrow("requires DAHLIA_AI_BACKEND=databricks");
  });
});
