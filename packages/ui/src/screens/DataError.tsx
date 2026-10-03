import { uiText } from "../api/api";

export function DataError({ error, retry }: { error?: Error; retry: () => void }) {
  return error ? <p className="error" role="alert">{error.message} <button className="secondary" onClick={retry}>{uiText("Retry", "再試行")}</button></p> : null;
}
