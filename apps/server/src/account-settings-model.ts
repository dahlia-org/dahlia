import { z } from "zod";

const analysisLanguages = z.object({
  scope: z.enum(["all", "selected"]),
  identifiers: z.array(z.string().regex(/^[a-z]{2,3}(?:-[A-Z][a-z]{3})?$/)).max(200)
    .transform((values) => [...new Set(values)].sort()),
}).strict().refine((value) => value.scope === "all" || value.identifiers.length > 0);

export const accountSettingsSchema = z.object({ analysisLanguages }).strict();
export type AccountSettings = z.infer<typeof accountSettingsSchema>;
export const DEFAULT_ACCOUNT_SETTINGS: AccountSettings = {
  analysisLanguages: { scope: "all", identifiers: [] },
};
export const accountSettingsPatchSchema = accountSettingsSchema.extend({ initialize: z.boolean().optional() });
export type AccountSettingsPatch = AccountSettings;
