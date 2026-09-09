import { Select } from "./Select";
import { useEffect, useRef, useState } from "react";
import { json, uiText } from "./api";
import { useLivePage, useLiveQuery } from "./live-data";
import { TranscriptTime } from "./MeetingContent";
import { transcriptStatus, TRANSCRIPT_ACTIVITY_WINDOW_MS, type TranscriptMetadata } from "../sync/transcript";

function transcriptStatusLabel(status: ReturnType<typeof transcriptStatus>): string {
  switch (status) {
    case "ended": return uiText("Generation ended", "生成終了確認済み");
    case "active": return uiText("Recent generation activity", "直近の生成活動あり");
    case "inactive": return uiText("No recent generation activity", "直近の生成活動なし");
    case "unknown": return uiText("Activity unknown", "活動状態不明");
  }
}

interface Version {
  id: string;
  version: number;
  endedAt: string | null;
  latestSegmentCreatedAt: string | null;
  createdAt: string;
  metadata: TranscriptMetadata | null;
}
interface Body {
  version: number;
  syncRevision: number;
  transcript: Version | null;
  items: { segmentId: string; startedAt: string; text: string; speakerLabel: string | null }[];
  nextCursor: string | null;
}

export async function readTranscriptPages(url: string, minimum: number, signal: AbortSignal): Promise<Body> {
  const first = await json<Body>(url, { signal });
  const result = { ...first, items: [...first.items] };
  while (result.nextCursor && result.items.length < minimum) {
    const page = await json<Body>(`${url}?cursor=${encodeURIComponent(result.nextCursor)}`, { signal });
    if (page.version !== first.version || page.syncRevision !== first.syncRevision) {
      throw new Error(uiText("The transcript changed. Retry to load the current version.", "文字起こしが更新されました。再試行してください。"));
    }
    if (page.nextCursor === result.nextCursor || !page.items.length) throw new Error("Invalid transcript page");
    result.items.push(...page.items);
    result.nextCursor = page.nextCursor;
  }
  return result;
}

export function useTranscriptStatus(version: Version | null | undefined) {
  const [now, setNow] = useState(() => Date.now());
  const latest = version?.latestSegmentCreatedAt ? Date.parse(version.latestSegmentCreatedAt) : null;
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const refresh = () => {
      const current = Date.now();
      setNow(current);
      if (version?.endedAt || latest === null) return;
      const delay = latest + TRANSCRIPT_ACTIVITY_WINDOW_MS + 1 - current;
      if (delay > 0) timer = setTimeout(refresh, Math.min(delay, 2_147_483_647));
    };
    refresh();
    return () => clearTimeout(timer);
  }, [version?.endedAt, latest]);
  return transcriptStatus(version?.endedAt ? new Date(version.endedAt) : null, latest === null ? null : new Date(latest), new Date(now));
}

export function TranscriptHistory({ base, timeBase }: { base: string; timeBase: string }) {
  const [selected, setSelected] = useState<number | null>(null);
  const demand = useRef(1);
  const versions = useLivePage<Version>(`${base}/transcript`);
  const url = `${base}/transcript/${selected ?? "latest"}`;
  const body = useLiveQuery<Body>(url, (signal, previous) =>
    readTranscriptPages(url, Math.max(demand.current, previous?.items.length ?? 1), signal));
  const metadata = body.data?.transcript?.metadata;
  const status = useTranscriptStatus(body.data?.transcript);
  const error = versions.error ?? body.error;
  return <div className="transcript-document">
    <div className="history-toolbar">
      <label>{uiText("Version", "バージョン")} <Select value={selected ?? "latest"} onValueChange={(value) => {
        demand.current = 1;
        setSelected(value === "latest" ? null : Number(value));
      }}>
        <option value="latest">{uiText("Current", "現在")}</option>
        {versions.data?.items.map((version) => <option key={version.id} value={version.version}>
          v{version.version} · {new Date(version.createdAt).toLocaleString()} · {version.metadata?.request.model ?? "—"}
        </option>)}
      </Select></label>
      {versions.data?.nextCursor && <button className="secondary" disabled={versions.loadingMore} onClick={versions.loadMore}>{uiText("Load older versions", "以前の版を読み込む")}</button>}
      {body.data?.transcript && <span role="status" title={uiText("Activity is estimated from segment creation times; it does not indicate connection or recording state.", "セグメントの作成日時から推定した活動状態です。接続や録音継続を示すものではありません。")}>{
        transcriptStatusLabel(status)
      }</span>}
      {selected !== null && <span>{uiText("Read-only version", "過去版（閲覧のみ）")}</span>}
    </div>
    {error && <p role="alert" className="error">{error.message} <button className="secondary" onClick={() => { versions.reload(); body.reload(); }}>{uiText("Retry", "再試行")}</button></p>}
    {body.loading && !body.data && <p role="status">{uiText("Loading…", "読み込み中…")}</p>}
    {metadata && <details className="summary-generation-metadata">
      <summary>{uiText("Generation details", "生成情報")} · {metadata.request.model}</summary>
      <dl><dt>{uiText("Provider / model", "プロバイダー・モデル")}</dt><dd>{metadata.provider} / {metadata.request.model}</dd></dl>
      {metadata.runs.map((run, index) => <dl key={index}>
        <dt>{uiText("Generated by", "生成したシステム")}</dt><dd>{run.generatedBy}</dd>
        <dt>{uiText("Language", "言語")}</dt><dd>{run.language?.mode ?? "—"} / {run.recognitionLocales?.join(", ") ?? run.language?.locales.join(", ") ?? "—"}</dd>
        <dt>{uiText("Completed", "完了日時")}</dt><dd>{run.completedAt ? new Date(run.completedAt).toLocaleString() : "—"}</dd>
        {run.response && <>
          <dt>{uiText("Response model", "応答モデル")}</dt><dd>{run.response.model ?? "—"}</dd>
          <dt>{uiText("Input / output / total tokens", "入力・出力・合計トークン")}</dt><dd>{run.response.usage?.input_tokens ?? "—"} / {run.response.usage?.output_tokens ?? "—"} / {run.response.usage?.total_tokens ?? "—"}</dd>
          {run.response.id && <><dt>{uiText("Response ID", "応答 ID")}</dt><dd>{run.response.id}</dd></>}
        </>}
      </dl>)}
    </details>}
    {body.data?.items.length === 0 && <p className="content-empty">{uiText("No transcript", "文字起こしはありません")}</p>}
    {body.data?.items.map((segment) => <div className="transcript-segment" key={segment.segmentId}>
      <TranscriptTime startTime={segment.startedAt} timeBase={timeBase} />
      <p>{segment.speakerLabel && <strong>{segment.speakerLabel}: </strong>}{segment.text}</p>
    </div>)}
    {body.data?.nextCursor && <button className="secondary" disabled={body.loading} onClick={() => {
      demand.current = (body.data?.items.length ?? 0) + 1;
      body.reload();
    }}>{uiText("Load more", "さらに表示")}</button>}
  </div>;
}
