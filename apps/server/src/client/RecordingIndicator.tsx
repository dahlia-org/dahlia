import { uiText } from "./api";

export function RecordingIndicator({ isRecording }: { isRecording?: boolean }) {
  return isRecording ? <span className="inline-flex items-center gap-1.5 rounded-full bg-red-50 px-2.5 py-1 text-xs font-medium text-red-700" role="status">
    <span className="size-2 animate-pulse rounded-full bg-red-500 motion-reduce:animate-none" aria-hidden="true" />{uiText("Recording", "録音中")}
  </span> : null;
}
