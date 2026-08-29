import type { DatabricksWorkspaceConfig } from "../config";
import { DatabricksTokenError, DatabricksTokenProvider } from "../databricks/token";
import { ObjectStorageError, type ArtifactReadMethod, type ObjectStorage } from "./storage";

export class DatabricksVolumeObjectStorage implements ObjectStorage {
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
    if (!response.ok) throw new ObjectStorageError();
  }

  async exists(key: string, signal?: AbortSignal): Promise<boolean> {
    const response = await this.send(key, { method: "HEAD", signal });
    if (response.status === 404) return false;
    if (!response.ok) throw new ObjectStorageError();
    return true;
  }

  async read(key: string, method: ArtifactReadMethod, request: Request): Promise<Response> {
    const headers = new Headers();
    for (const name of ["range", "if-unmodified-since"]) {
      const value = request.headers.get(name);
      if (value) headers.set(name, value);
    }
    const upstream = await this.send(key, { method, headers, signal: request.signal });
    if (upstream.status === 404) return new Response(null, { status: 404 });
    if (!upstream.ok && upstream.status !== 412 && upstream.status !== 416) {
      throw new ObjectStorageError();
    }
    if (upstream.status === 412 || upstream.status === 416) {
      const headers = new Headers();
      const contentRange = upstream.headers.get("content-range");
      if (contentRange) headers.set("content-range", contentRange);
      return new Response(null, { status: upstream.status, headers });
    }
    return new Response(method === "HEAD" ? null : upstream.body, upstream);
  }

  async delete(key: string, signal?: AbortSignal): Promise<void> {
    const response = await this.send(key, { method: "DELETE", signal });
    if (!response.ok && response.status !== 404) throw new ObjectStorageError();
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
      if (error instanceof DatabricksTokenError) throw new ObjectStorageError("artifact_storage_authentication_failed");
      if (error instanceof ObjectStorageError) throw error;
      throw new ObjectStorageError();
    }
  }
}
