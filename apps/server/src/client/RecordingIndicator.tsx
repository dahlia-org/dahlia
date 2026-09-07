import { uiText } from "./api";

export function RecordingIndicator({ isRecording }: { isRecording?: boolean }) {
  return isRecording ? <span className="recording-indicator" role="status">
    <span className="recording-dot" aria-hidden="true" />{uiText("Recording", "録音中")}
  </span> : null;
}
