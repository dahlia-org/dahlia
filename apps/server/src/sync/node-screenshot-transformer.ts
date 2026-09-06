import sharp from "sharp";
import { DEFAULT_ARTIFACT_MAX_BYTES } from "../config";
import type { ScreenshotTransformer } from "./screenshot-variants";

// Native decoding and image buffers stay out of the Worker graph and off the event loop.
export const transformScreenshot: ScreenshotTransformer = async (source, longEdge) => {
  let length = 0;
  const bounded = source.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      length += chunk.byteLength;
      if (length > DEFAULT_ARTIFACT_MAX_BYTES) throw new Error("screenshot_too_large");
      controller.enqueue(chunk);
    },
  }));
  const bytes = await new Response(bounded).arrayBuffer();
  const output = await sharp(bytes, { limitInputPixels: 33_554_432, pages: 1 })
    .rotate()
    .resize(longEdge, longEdge, { fit: "inside", withoutEnlargement: true })
    .webp({ quality: 75 })
    .timeout({ seconds: 15 })
    .toBuffer();
  return new Uint8Array(output);
};
