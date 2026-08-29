import { AwsClient } from "aws4fetch";

import type { S3StorageConfig } from "../config";
import { ObjectStorageError, type ArtifactReadMethod, type ObjectStorage } from "./storage";

export class S3ObjectStorage implements ObjectStorage {
  private readonly signer: AwsClient;

  constructor(
    private readonly config: S3StorageConfig,
    private readonly transport: typeof fetch = fetch,
  ) {
    this.signer = new AwsClient({
      accessKeyId: config.accessKeyId,
      secretAccessKey: config.secretAccessKey,
      sessionToken: config.sessionToken,
      region: config.region,
      service: "s3",
    });
  }

  async put(
    key: string,
    body: ReadableStream<Uint8Array> | Uint8Array,
    contentLength: number,
    contentType: string,
    signal?: AbortSignal,
  ): Promise<void> {
    const response = await this.send(key, {
      method: "PUT",
      headers: {
        "cache-control": "private, no-store",
        "content-length": String(contentLength),
        "content-type": contentType,
        "x-amz-content-sha256": "UNSIGNED-PAYLOAD",
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
    const response = await this.send(key, { method, headers, signal: request.signal });
    if (response.status === 404) return new Response(null, { status: 404 });
    if (response.status === 412 || response.status === 416) {
      const safe = new Headers();
      const contentRange = response.headers.get("content-range");
      if (contentRange) safe.set("content-range", contentRange);
      return new Response(null, { status: response.status, headers: safe });
    }
    if (!response.ok) throw new ObjectStorageError();
    return response;
  }

  async delete(key: string, signal?: AbortSignal): Promise<void> {
    const response = await this.send(key, { method: "DELETE", signal });
    if (!response.ok && response.status !== 404) throw new ObjectStorageError();
  }

  private async send(key: string, init: RequestInit): Promise<Response> {
    try {
      const signed = await this.signer.sign(this.url(key), init);
      return await this.transport(signed);
    } catch {
      throw new ObjectStorageError();
    }
  }

  private url(key: string): string {
    const encodedKey = key.split("/").map(encodeURIComponent).join("/");
    if (this.config.endpoint) {
      return `${this.config.endpoint}/${encodeURIComponent(this.config.bucket)}/${encodedKey}`;
    }
    return `https://${this.config.bucket}.s3.${this.config.region}.amazonaws.com/${encodedKey}`;
  }
}
