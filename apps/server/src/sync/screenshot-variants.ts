export const SCREENSHOT_VARIANTS = { thumbnail: 384 } as const;
export type ScreenshotVariant = keyof typeof SCREENSHOT_VARIANTS;
export type ScreenshotTransformer = (source: ReadableStream<Uint8Array>, longEdge: number) => Promise<Uint8Array<ArrayBuffer>>;

export function screenshotVariantKey(originalKey: string, variant: ScreenshotVariant): string {
  // Original IDs are immutable. Fixed keys also let durable deletion remove derivatives after the row is gone.
  return `${originalKey}.v1-${variant}.webp`;
}
