// Types and constants shared by the main process, the preload and the renderer.

export type AudioSource = "mic" | "system";
export const audioSources: readonly AudioSource[] = ["mic", "system"];

export type RecordingStatus = "recording" | "recorded" | "transcribing" | "transcribed" | "failed";

export type Recording = {
  id: string;
  meetingId: string;
  startedAt: number;
  endedAt?: number;
  durationMs: number;
  /** Where this recording starts on the meeting's timeline: the length of its earlier recordings. */
  offsetMs: number;
  locale: string;
  status: RecordingStatus;
  error?: string;
};

export type TranscriptSegment = {
  id: string;
  recordingId: string;
  source: AudioSource;
  /** Relative to the recording. Add offsetMs for the meeting's timeline. */
  startMs: number;
  endMs: number;
  offsetMs: number;
  text: string;
};

/** A subset of Dahlia for macOS's SummaryDocumentResponse: no images, tables, code or tags. */
export type SummaryItem = { text: string; transcript_ref: string | null };
export type SummaryBlock =
  | { type: "paragraph" | "heading"; text: string; transcript_ref: string | null }
  | { type: "bulleted_list" | "numbered_list"; items: SummaryItem[] }
  | { type: "checklist"; items: (SummaryItem & { checked: boolean })[] };
export type SummarySection = { heading: string; blocks: SummaryBlock[] };
export type SummaryActionItem = { text: string; assignee: string | null; transcript_ref: string | null };
export type SummaryDocument = {
  title: string;
  description: string;
  sections: SummarySection[];
  action_items: SummaryActionItem[];
};

export type SummaryState = {
  status: "generating" | "ready" | "failed";
  /** The last good summary; kept while a new one generates or after it fails. */
  document?: SummaryDocument;
  model?: string;
  error?: string;
  createdAt: number;
};

export type MeetingSummary = { id: string; name: string; createdAt: number; busy: boolean };

export type Meeting = {
  id: string;
  name: string;
  description: string;
  createdAt: number;
  recordings: Recording[];
  segments: TranscriptSegment[];
  summary?: SummaryState;
};

export type Settings = {
  transcriptionLocale: string;
  summaryLanguage: string;
  summaryModel: string;
};

export type AuthState =
  | { status: "signedOut"; error?: string }
  | { status: "signingIn"; workspace: string }
  | { status: "signedIn"; workspace: string; email: string };

/** Transient progress the main process reports while it works; the database holds the outcomes. */
export type Progress = { meetingId: string; step: "transcribing" | "summarizing"; fraction?: number; detail?: "downloadingModel" };

export type ActiveRecording = { meetingId: string; recordingId: string; startedAt: number };
/** `error` is why the last recording stopped on its own, such as a failed write. */
export type RecordingState = { active?: ActiveRecording; error?: string };

export type DahliaAPI = {
  auth: {
    state(): Promise<AuthState>;
    signIn(workspace: string): Promise<void>;
    cancelSignIn(): Promise<void>;
    signOut(): Promise<void>;
  };
  meetings: {
    list(): Promise<MeetingSummary[]>;
    get(id: string): Promise<Meeting | undefined>;
    create(): Promise<string>;
    rename(id: string, name: string): Promise<void>;
    delete(id: string): Promise<void>;
  };
  recording: {
    state(): Promise<RecordingState>;
    start(meetingId: string): Promise<ActiveRecording>;
    append(recordingId: string, source: AudioSource, chunk: ArrayBuffer): void;
    stop(recordingId: string, error?: "captureEnded" | "captureFailed"): Promise<void>;
    onStopRequested(listener: () => void): () => void;
  };
  processing: {
    retranscribe(meetingId: string): Promise<void>;
    summarize(meetingId: string): Promise<void>;
    progress(): Promise<Progress[]>;
  };
  settings: {
    get(): Promise<Settings>;
    set(patch: Partial<Settings>): Promise<Settings>;
    models(): Promise<string[]>;
    locales(): Promise<string[]>;
  };
  /** Called whenever stored data, auth or progress changes; the renderer reloads what it shows. */
  onChange(listener: () => void): () => void;
};
