import { describe, expect, it } from "vitest";
import { fileMetadataLimits, fileMetadataSchema } from "../src/files/model";
import { imageAnalysisSchema } from "../src/image-analysis/model";

function exactCodePoints(token: string, count: number): string {
  const width = [...token].length;
  return token.repeat(Math.floor(count / width)) + "a".repeat(count % width);
}

describe("file metadata Unicode limits", () => {
  it.each(["a", "日", "😀", "👨‍👩‍👧‍👦", "e\u0301"])("counts %s as Unicode code points", (token) => {
    const parse = (ocrText: string) => fileMetadataSchema.safeParse({ source: "screenshot", ocr_text: ocrText });
    expect(parse(exactCodePoints(token, fileMetadataLimits.api.ocrText - 1)).success).toBe(true);
    expect(parse(exactCodePoints(token, fileMetadataLimits.api.ocrText)).success).toBe(true);
    expect(parse(exactCodePoints(token, fileMetadataLimits.api.ocrText + 1)).success).toBe(false);
  });

  it("uses code points rather than JavaScript UTF-16 length at the API boundaries", () => {
    const ocrText = "😀".repeat(fileMetadataLimits.api.ocrText);
    const caption = "😀".repeat(fileMetadataLimits.api.caption);
    expect(ocrText.length).toBe(fileMetadataLimits.api.ocrText * 2);
    expect(caption.length).toBe(fileMetadataLimits.api.caption * 2);
    expect(fileMetadataSchema.safeParse({ source: "screenshot", ocr_text: ocrText, caption }).success).toBe(true);
    expect(fileMetadataSchema.safeParse({ source: "screenshot", ocr_text: `${ocrText}x`, caption }).success).toBe(false);
    expect(fileMetadataSchema.safeParse({ source: "screenshot", ocr_text: ocrText, caption: `${caption}x` }).success).toBe(false);
    expect(imageAnalysisSchema.safeParse({ ocr_text: ocrText, caption }).success).toBe(true);
  });
});
