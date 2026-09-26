import type { Identity } from "../auth/identity";
import { RequestError } from "../storage/upload";
import type { MeetingSyncService } from "../sync/service";
import type { MeetingSyncStore, SyncScreenshotRecord } from "../sync/types";
import type { CaptionerImage, ImageCaptioner } from "./captioner";
import { ImageAnalysisError, type ImageAnalysisClaim, type ImageAnalysisInput } from "./model";
import type { ImageAnalysisStore, ImageAnalysisReference } from "./store";

const IMAGE_BYTES = 4 * 1024 * 1024;
const BATCH_BYTES = 32 * 1024 * 1024;

export async function processImageAnalysisJob(
  jobs: ImageAnalysisStore, captioner: ImageCaptioner, syncStore: MeetingSyncStore,
  sync: MeetingSyncService, signal: AbortSignal,
  reference?: ImageAnalysisReference,
): Promise<boolean> {
  signal = AbortSignal.any([signal, AbortSignal.timeout(240_000)]);
  const job = await jobs.claim(captioner.model, reference);
  if (!job) return false;
  const identity: Identity = { userId: job.ownerUserId, source: "accounts" };
  const pending = new Map<string, ImageAnalysisClaim>([[job.fileId, job]]);
  const finish = async (claim: ImageAnalysisClaim, error?: unknown) => {
    pending.delete(claim.fileId);
    if (!error) return jobs.finish(claim);
    const failure = error instanceof ImageAnalysisError ? error
      : error instanceof RequestError
        ? new ImageAnalysisError(`captioning_image_http_${error.status}`, error.status === 429 || error.status >= 500)
        : new ImageAnalysisError("captioning_processing_failed", true);
    await jobs.finish(claim, {
      code: failure.code,
      retryAt: failure.retryable ? new Date(Date.now() + Math.min(15 * 60_000, 1_000 * 2 ** Math.min(claim.attempts, 10))) : undefined,
    });
  };
  try {
    // A retried job runs alone so one bad image cannot keep failing its neighbors.
    const batchSize = job.attempts === 0 ? Math.max(1, captioner.batchSize ?? 1) : 1;
    const batch = await jobs.claimBatch(job, batchSize - 1);
    for (const claim of batch.claims) pending.set(claim.fileId, claim);
    const screenshots = batch.meetingId ? await meetingScreenshots(syncStore, identity, job.workspaceId, batch.meetingId) : [];
    const order = new Map(screenshots.map((screenshot, index) => [screenshot.fileId, index]));
    const inputs: ImageAnalysisInput[] = [];
    for (const claim of [...pending.values()]) {
      const input = await syncStore.withIdentity(identity, (scoped) => scoped.loadImageAnalysis(claim));
      if (input) inputs.push(input);
      else await finish(claim);
    }
    if (!inputs.length) return true;
    inputs.sort((left, right) => (order.get(left.fileId) ?? -1) - (order.get(right.fileId) ?? -1));

    // Each target is preceded by its predecessor so the model can flag unchanged periodic captures.
    const images: (CaptionerImage & { fileId: string; input?: ImageAnalysisInput })[] = [];
    let bytes = 0;
    for (const input of inputs) {
      const position = order.get(input.fileId);
      const previous = position ? screenshots[position - 1] : undefined;
      const needsReference = previous && images.at(-1)?.fileId !== previous.fileId;
      let referenceData: Uint8Array | undefined;
      if (needsReference) referenceData = await readImage(sync, identity, previous.fileId, signal).catch(() => undefined);
      let data: Uint8Array;
      try {
        data = await readImage(sync, identity, input.fileId, signal);
      } catch (error) {
        if (signal.aborted) throw error;
        await finish(input, error);
        continue;
      }
      const added = data.byteLength + (referenceData?.byteLength ?? 0);
      if (images.some((image) => image.input) && bytes + added > BATCH_BYTES) {
        pending.delete(input.fileId);
        await jobs.release(input);
        continue;
      }
      bytes += added;
      if (referenceData) images.push({ fileId: previous!.fileId, data: referenceData, reference: true });
      images.push({ fileId: input.fileId, data, input });
    }
    const targets = images.filter((image) => image.input);
    if (!targets.length) return true;
    let analyses;
    try {
      analyses = await captioner.analyze(images, { outputLanguage: job.outputLanguage }, signal);
    } catch (error) {
      if (targets.length === 1 || signal.aborted || !(error instanceof ImageAnalysisError)) throw error;
      // Retry each image alone; single-image failures keep their own classification.
      throw new ImageAnalysisError(error.code, true);
    }
    signal.throwIfAborted();
    for (const [index, target] of targets.entries()) {
      const before = images[images.indexOf(target) - 1];
      pending.delete(target.fileId);
      if (!await sync.completeImageAnalysis(identity, target.input!, analyses[index]!, before?.fileId ?? null)) {
        await jobs.finish(target.input!, { code: "stale_image", retryAt: new Date() });
      }
    }
  } catch (error) {
    if (!(error instanceof ImageAnalysisError) && !(error instanceof RequestError) && !signal.aborted) throw error;
    for (const claim of [...pending.values()]) await finish(claim, error);
  }
  return true;
}

async function meetingScreenshots(syncStore: MeetingSyncStore, identity: Identity, workspaceId: string, meetingId: string) {
  const screenshots: SyncScreenshotRecord[] = [];
  while (true) {
    const last = screenshots.at(-1);
    const page = await syncStore.withIdentity(identity, (scoped) => scoped.listScreenshots(workspaceId, meetingId, undefined, 200,
      last ? { capturedAt: last.capturedAt, screenshotId: last.screenshotId } : undefined));
    screenshots.push(...page);
    if (page.length < 200 || screenshots.length >= 5000) return screenshots;
  }
}

async function readImage(sync: MeetingSyncService, identity: Identity, fileId: string, signal: AbortSignal) {
  const { upstream } = await sync.readFileContent(identity, fileId, "thumb_1280", "GET",
    new Request("https://dahlia.invalid/", { signal }));
  if (!upstream.ok) {
    await upstream.body?.cancel();
    throw new ImageAnalysisError(`captioning_image_http_${upstream.status}`, upstream.status === 429 || upstream.status >= 500);
  }
  let length = 0;
  const bounded = upstream.body?.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      length += chunk.byteLength;
      if (length > IMAGE_BYTES) throw new ImageAnalysisError("captioning_image_too_large", false);
      controller.enqueue(chunk);
    },
  }));
  return new Uint8Array(await new Response(bounded).arrayBuffer());
}
