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
    const directory = key.slice(0, key.lastIndexOf("/"));
    if (directory) {
      const directoryResponse = await this.send(`${directory}/`, { method: "PUT", signal }, "directories");
      if (!directoryResponse.ok) throw databricksStorageUpstreamError("create_directory", directoryResponse);
    }
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
    if (!response.ok) throw databricksStorageUpstreamError("put", response);
  }

  async exists(key: string, signal?: AbortSignal): Promise<boolean> {
    const response = await this.send(key, { method: "HEAD", signal });
    if (response.status === 404) return false;
    if (!response.ok) throw databricksStorageUpstreamError("exists", response);
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
      throw databricksStorageUpstreamError(method.toLowerCase(), upstream);
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
    if (!response.ok && response.status !== 404) throw databricksStorageUpstreamError("delete", response);
  }

  private async send(
    key: string,
    init: RequestInit,
    resource: "directories" | "files" = "files",
  ): Promise<Response> {
    const path = `${this.volumePath}/${key}`.split("/").map(encodeURIComponent).join("/");
    try {
      const token = await this.tokens.getToken();
      const headers = new Headers(init.headers);
      headers.set("authorization", `Bearer ${token}`);
      const overwrite = resource === "files" && init.method === "PUT" ? "?overwrite=true" : "";
      const url = `${this.config.host}/api/2.0/fs/${resource}${path}${overwrite}`;
      return await this.transport(url, {
        ...init,
        headers,
      });
    } catch (error) {
      const operation = resource === "directories" ? "create_directory" : String(init.method ?? "GET").toLowerCase();
      if (error instanceof DatabricksTokenError) {
        logDatabricksStorageFailure("authentication_failed", operation);
        throw new ObjectStorageError("artifact_storage_authentication_failed");
      }
      if (error instanceof ObjectStorageError) throw error;
      logDatabricksStorageFailure("transport_error", operation);
      throw new ObjectStorageError();
    }
  }
}

function databricksStorageUpstreamError(operation: string, response: Response): ObjectStorageError {
  const requestId = response.headers.get("x-databricks-request-id")
    || response.headers.get("x-request-id")
    || response.headers.get("request-id")
    || undefined;
  logDatabricksStorageFailure("upstream_http_error", operation, response.status, requestId);
  return new ObjectStorageError();
}

function logDatabricksStorageFailure(
  reason: "authentication_failed" | "transport_error" | "upstream_http_error",
  operation: string,
  status?: number,
  requestId?: string,
): void {
  console.error(JSON.stringify({
    level: "error",
    event: "databricks_artifact_storage_failed",
    reason,
    operation,
    ...(status === undefined ? {} : { status }),
    ...(requestId ? { requestId } : {}),
  }));
}
