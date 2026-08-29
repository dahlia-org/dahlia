import type { DatabricksWorkspaceConfig } from "../config";
import { DatabricksTokenError, DatabricksTokenProvider } from "../databricks/token";
import { ArtifactStorageError, type ArtifactReadMethod, type ArtifactStorage } from "./storage";

const FORWARDED_RESPONSE_HEADERS = [
  "accept-ranges",
  "content-length",
  "content-range",
  "last-modified",
] as const;

export class DatabricksVolumeArtifactStorage implements ArtifactStorage {
  private readonly tokens: DatabricksTokenProvider;

  constructor(
    private readonly config: DatabricksWorkspaceConfig,
    private readonly volumePath: string,
    private readonly transport: typeof fetch = fetch,
  ) {
    this.tokens = new DatabricksTokenProvider(config, transport);
  }

  async put(
    key: string,
    body: ReadableStream<Uint8Array> | Uint8Array,
    contentLength: number,
    contentType: string,
    signal?: AbortSignal,
  ): Promise<void> {
    void contentType;
    const response = await this.send(key, {
      method: "PUT",
      headers: {
        "content-length": String(contentLength),
        "content-type": "application/octet-stream",
      },
      body,
      duplex: "half",
      signal,
    } as RequestInit & { duplex: "half" });
    if (!response.ok) throw new ArtifactStorageError();
  }

  async exists(key: string, signal?: AbortSignal): Promise<boolean> {
    const response = await this.send(key, { method: "HEAD", signal });
    if (response.status === 404) return false;
    if (!response.ok) throw new ArtifactStorageError();
    return true;
  }

  async read(key: string, method: ArtifactReadMethod, request: Request, contentType: string): Promise<Response> {
    const headers = new Headers();
    for (const name of ["range", "if-unmodified-since"]) {
      const value = request.headers.get(name);
      if (value) headers.set(name, value);
    }
    const upstream = await this.send(key, { method, headers, signal: request.signal });
    if (upstream.status === 404) return new Response(null, { status: 404 });
    if (!upstream.ok && upstream.status !== 412 && upstream.status !== 416) {
      throw new ArtifactStorageError();
    }
    if (upstream.status === 412 || upstream.status === 416) {
      return new Response(null, { status: upstream.status });
    }
    const responseHeaders = new Headers({
      "content-security-policy": "sandbox allow-scripts",
      "content-type": contentType,
    });
    for (const name of FORWARDED_RESPONSE_HEADERS) {
      const value = upstream.headers.get(name);
      if (value) responseHeaders.set(name, value);
    }
    return new Response(method === "HEAD" ? null : upstream.body, {
      status: upstream.status,
      headers: responseHeaders,
    });
  }

  async delete(key: string, signal?: AbortSignal): Promise<void> {
    const response = await this.send(key, { method: "DELETE", signal });
    if (!response.ok && response.status !== 404) throw new ArtifactStorageError();
  }

  private async send(key: string, init: RequestInit): Promise<Response> {
    const path = `${this.volumePath}/${key}`.split("/").map(encodeURIComponent).join("/");
    try {
      const token = await this.tokens.getToken();
      const headers = new Headers(init.headers);
      headers.set("authorization", `Bearer ${token}`);
      const url = `${this.config.host}/api/2.0/fs/files${path}${init.method === "PUT" ? "?overwrite=true" : ""}`;
      return await this.transport(url, {
        ...init,
        headers,
      });
    } catch (error) {
      if (error instanceof DatabricksTokenError) throw new ArtifactStorageError("artifact_storage_authentication_failed");
      if (error instanceof ArtifactStorageError) throw error;
      throw new ArtifactStorageError();
    }
  }
}
