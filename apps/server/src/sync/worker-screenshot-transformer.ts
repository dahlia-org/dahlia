import { MAX_FILE_BYTES } from "../config";
import type { ScreenshotTransformer } from "./screenshot-variants";

export function createWorkerScreenshotTransformer(images: Pick<ImagesBinding, "input">): ScreenshotTransformer {
  return async (source, longEdge) => {
    let length = 0;
    const bounded = source.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        length += chunk.byteLength;
        if (length > MAX_FILE_BYTES) throw new Error("screenshot_too_large");
        controller.enqueue(chunk);
      },
    }));
    const output = await images.input(bounded).transform({ width: longEdge, height: longEdge, fit: "scale-down" })
      .output({ format: "image/webp", quality: 80 });
    let outputLength = 0;
    const result = output.image().pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        outputLength += chunk.byteLength;
        if (outputLength > 4 * 1024 * 1024) throw new Error("screenshot_variant_too_large");
        controller.enqueue(chunk);
      },
    }));
    return new Uint8Array(await new Response(result).arrayBuffer());
  };
}
