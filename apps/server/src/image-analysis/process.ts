import { DEFAULT_ACCOUNT_SETTINGS, type AccountSettingsStore } from "../account-settings";
import type { Identity } from "../auth/identity";
import { personalWorkspaceId } from "../auth/workspace";
import { RequestError } from "../storage/upload";
import type { MeetingSyncService } from "../sync/service";
import type { MeetingSyncStore } from "../sync/types";
import type { ImageCaptioner } from "./captioner";
import { ImageAnalysisError } from "./model";
import type { ImageAnalysisStore, ImageAnalysisReference } from "./store";


export async function processImageAnalysisJob(
  jobs: ImageAnalysisStore, captioner: ImageCaptioner, syncStore: MeetingSyncStore,
  sync: MeetingSyncService, accountSettings: AccountSettingsStore, signal: AbortSignal,
  reference?: ImageAnalysisReference,
): Promise<boolean> {
  signal = AbortSignal.any([signal, AbortSignal.timeout(240_000)]);
  const job = await jobs.claim(captioner.model, reference);
  if (!job) return false;
  const identity: Identity = { userId: job.ownerUserId, workspaceId: personalWorkspaceId(job.ownerUserId), source: "accounts" };
  try {
    const input = await syncStore.withIdentity(identity, (scoped) => scoped.loadImageAnalysis(job));
    if (!input) {
      await jobs.finish(job);
      return true;
    }
    const settings = await accountSettings.get(job.ownerUserId) ?? DEFAULT_ACCOUNT_SETTINGS;
    const { upstream } = await sync.readFileContent(identity, job.fileId, "thumb_1280", "GET",
      new Request("https://dahlia.invalid/", { signal }));
    if (!upstream.ok) {
      await upstream.body?.cancel();
      throw new ImageAnalysisError(`captioning_image_http_${upstream.status}`, upstream.status === 429 || upstream.status >= 500);
    }
    let length = 0;
    const bounded = upstream.body?.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        length += chunk.byteLength;
        if (length > 4 * 1024 * 1024) throw new ImageAnalysisError("captioning_image_too_large", false);
        controller.enqueue(chunk);
      },
    }));
    const bytes = new Uint8Array(await new Response(bounded).arrayBuffer());
    signal.throwIfAborted();
    if (!await syncStore.withIdentity(identity, (scoped) => scoped.loadImageAnalysis(job))) {
      await jobs.finish(job);
      return true;
    }
    const analysis = await captioner.analyze(bytes, settings, signal).catch((error: unknown) => {
      throw error instanceof ImageAnalysisError ? error : new ImageAnalysisError("captioning_processing_failed", true);
    });
    signal.throwIfAborted();
    if (!await sync.completeImageAnalysis(identity, input, analysis)) {
      await jobs.finish(job, { code: "stale_image", retryAt: new Date() });
    }
  } catch (error) {
    if (!(error instanceof ImageAnalysisError) && !(error instanceof RequestError) && !signal.aborted) throw error;
    const failure = error instanceof ImageAnalysisError ? error
      : error instanceof RequestError
        ? new ImageAnalysisError(`captioning_image_http_${error.status}`, error.status === 429 || error.status >= 500)
        : new ImageAnalysisError("captioning_processing_failed", true);
    await jobs.finish(job, {
      code: failure.code,
      retryAt: failure.retryable ? new Date(Date.now() + Math.min(15 * 60_000, 1_000 * 2 ** Math.min(job.attempts, 10))) : undefined,
    });
  }
  return true;
}
