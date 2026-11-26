import { randomUUID } from "node:crypto";

/** Pi's generic RPC confirm has no cancellation output, so Dahlia uses correlated bridge requests. */
export async function confirmInHost(ctx: any, title: string, message: string, signal?: AbortSignal): Promise<boolean> {
  if (!ctx?.hasUI || signal?.aborted) return false;
  const requestID = randomUUID();
  let cancellation: Promise<unknown> | undefined;
  const cancel = () => {
    cancellation ??= Promise.resolve(ctx.ui.input("dahlia:cancelConfirmation", JSON.stringify({ requestID }))).catch(() => undefined);
  };
  const response = ctx.ui.input("dahlia:confirmation", JSON.stringify({ requestID, title, message }));
  signal?.addEventListener("abort", cancel, { once: true });
  if (signal?.aborted) cancel();
  try {
    const value = await response;
    return !signal?.aborted && value !== undefined && JSON.parse(value) === "accept";
  } finally {
    signal?.removeEventListener("abort", cancel);
    await cancellation;
  }
}
