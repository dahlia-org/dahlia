import { AwsClient } from "aws4fetch";

import type { R2ArtifactConfig } from "../config";
import { ArtifactStorageError, type ArtifactReadMethod, type ArtifactStorage } from "./storage";

export interface R2BucketLike {
  put(
    key: string,
    value: ReadableStream<Uint8Array> | Uint8Array,
    options: { httpMetadata: { cacheControl: string; contentType: string } },
  ): Promise<unknown>;
  head(key: string): Promise<unknown>;
  delete(key: string): Promise<void>;
}

const PRESIGNED_URL_SECONDS = 300;

export class R2ArtifactStorage implements ArtifactStorage {
  private readonly signer: AwsClient;

  constructor(
    private readonly bucket: R2BucketLike,
    private readonly config: R2ArtifactConfig,
  ) {
    this.signer = new AwsClient({
      accessKeyId: config.accessKeyId,
      secretAccessKey: config.secretAccessKey,
      region: "auto",
      service: "s3",
    });
  }

  async put(
    key: string,
    body: ReadableStream<Uint8Array> | Uint8Array,
    _contentLength: number,
    contentType: string,
  ): Promise<void> {
    try {
      await this.bucket.put(key, body, {
        httpMetadata: { cacheControl: "private, no-store", contentType },
      });
    } catch {
      throw new ArtifactStorageError();
    }
  }

  async exists(key: string): Promise<boolean> {
    try {
      return await this.bucket.head(key) !== null;
    } catch {
      throw new ArtifactStorageError();
    }
  }

  async read(key: string, method: ArtifactReadMethod): Promise<Response> {
    if (!await this.exists(key)) return new Response(null, { status: 404 });
    const url = new URL(`https://${this.config.accountId}.r2.cloudflarestorage.com`);
    url.pathname = `/${this.config.bucket}/${key}`;
    url.searchParams.set("X-Amz-Expires", String(PRESIGNED_URL_SECONDS));
    let signed: Request;
    try {
      signed = await this.signer.sign(new Request(url, { method }), { aws: { signQuery: true } });
    } catch {
      throw new ArtifactStorageError();
    }
    return new Response(null, {
      status: 307,
      headers: { location: signed.url },
    });
  }

  async delete(key: string): Promise<void> {
    try {
      await this.bucket.delete(key);
    } catch {
      throw new ArtifactStorageError();
    }
  }
}
