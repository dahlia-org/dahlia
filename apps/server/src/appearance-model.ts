import { z } from "zod";

export const appearanceSchema = z.object({
  icon: z.enum(["workspace", "folder", "dollarsign.circle", "book.closed", "graduationcap", "pencil", "tag", "curlybraces", "terminal", "music.note", "popcorn", "paintbrush", "paintpalette", "stethoscope", "asterisk", "camera.macro", "briefcase", "chart.bar", "medal", "dumbbell", "notebook", "scales", "globe.desk", "airplane", "globe", "wrench", "pawprint", "flask", "brain", "heart", "pottedplant", "film", "cross.case", "puzzlepiece", "leaf"]),
  color: z.enum(["neutral", "red", "orange", "yellow", "green", "blue", "purple", "pink"]),
}).strict();
export type Appearance = z.infer<typeof appearanceSchema>;
