import { canWriteVault } from "./auth/vault-permissions";
import { z } from "@hono/zod-openapi";
import type { Identity } from "./auth/identity";
import type { RecordingAudio, RecordingRecord, RecordingSource } from "./recordings/model";
import { RequestError } from "./storage/upload";
import type { TranscriptMetadata } from "./sync/transcript";
import type { MeetingSyncStore, TranscriptAnalyticsSegment } from "./sync/types";

export const CONVERSATION_ANALYTICS_VERSION = 1;
const SPEECH_MERGE_GAP = 1.5;
const MONOLOGUE_MERGE_GAP = 3;
const MAX_TIMELINE_INTERVALS = 512;
const MAX_PACE_SAMPLES = 60;
const MIN_PACE_BUCKET_DURATION = 60;
const sources = ["mic", "system"] as const;
const graphemes = new Intl.Segmenter("und", { granularity: "grapheme" });

export function normalizedCharacterCount(text: string): number {
  const normalized = text.replace(/\p{White_Space}/gu, "");
  return [...graphemes.segment(normalized)].length;
}

export const conversationAnalyticsSchema = z.object({
  status: z.literal("ready"),
  transcriptId: z.uuid(),
  transcriptVersion: z.number().int().positive(),
  calculationVersion: z.literal(CONVERSATION_ANALYTICS_VERSION),
  recordingDuration: z.number().nonnegative(),
  unionSpeechDuration: z.number().nonnegative(),
  overlapDuration: z.number().nonnegative(),
  conversationOccupancyRatio: z.number().nonnegative().nullable(),
  overlapRatio: z.number().nonnegative().nullable(),
  speechMergeGap: z.number().nonnegative(),
  monologueMergeGap: z.number().nonnegative(),
  sources: z.array(z.object({
    source: z.enum(sources), speechDuration: z.number().nonnegative(), normalizedCharacterCount: z.number().int().nonnegative(),
    segmentCount: z.number().int().nonnegative(), unmeasurableSegmentCount: z.number().int().nonnegative(),
    charactersPerMinute: z.number().nonnegative().nullable(), speechShare: z.number().nonnegative().nullable(),
  })),
  longestMonologue: z.object({ source: z.enum(sources), start: z.number().nonnegative(), end: z.number().nonnegative() }).nullable(),
  paceBucketDuration: z.number().positive(),
  paceSamples: z.array(z.object({
    source: z.enum(sources), start: z.number().nonnegative(), end: z.number().nonnegative(),
    charactersPerMinute: z.number().nonnegative(), seriesIndex: z.number().int().nonnegative(),
  })),
  timelineIntervals: z.array(z.object({ source: z.enum(sources), start: z.number().nonnegative(), end: z.number().nonnegative() })),
  overlapIntervals: z.array(z.object({ start: z.number().nonnegative(), end: z.number().nonnegative() })),
  overlapCount: z.number().int().nonnegative(),
  isTimelineCondensed: z.boolean(),
}).strict().openapi("ConversationAnalytics");

export const conversationAnalyticsUnavailableSchema = z.object({
  status: z.literal("unavailable"),
  transcriptId: z.uuid(),
  transcriptVersion: z.number().int().positive(),
  reason: z.literal("recording_audio_missing"),
}).strict().openapi("ConversationAnalyticsUnavailable");

export type ConversationAnalyticsResponse = z.infer<typeof conversationAnalyticsSchema> | z.infer<typeof conversationAnalyticsUnavailableSchema>;

interface Interval { start: number; end: number }
interface TimedSegment { interval: Interval; normalizedCharacterCount: number }
interface Accumulator {
  intervals: Interval[];
  timedSegments: TimedSegment[];
  normalizedCharacterCount: number;
  segmentCount: number;
  unmeasurableSegmentCount: number;
}
interface RecordingTimeline { record: RecordingRecord; offset: number; duration: number; sources: Set<RecordingSource> }

function isRecordingSource(source: string | null): source is RecordingSource {
  return source === "mic" || source === "system";
}

export class ConversationAnalyticsService {
  constructor(private readonly store: MeetingSyncStore) {}

  async get(identity: Identity, vaultId: string, meetingId: string, version: number): Promise<ConversationAnalyticsResponse> {
    return this.store.withIdentity(identity, async (scoped) => {
      if (!canWriteVault((await scoped.getVault(vaultId))?.role) || !await scoped.getMeeting(vaultId, meetingId)) {
        throw new RequestError(404, "conversation_analytics_unavailable");
      }
      const transcript = await scoped.getTranscript(vaultId, meetingId, version);
      if (!transcript) throw new RequestError(404, "transcript_version_not_found");
      if (transcript.endedAt === null) {
        const latest = await scoped.getTranscript(vaultId, meetingId);
        if (!latest || latest.version <= transcript.version) throw new RequestError(409, "transcript_version_not_finalized");
      }
      const recordings = await listAllRecordings(scoped.listRecordings.bind(scoped), meetingId);
      const segments = await scoped.listTranscriptAnalytics(vaultId, meetingId, version);
      const timeline = recordingTimeline(transcript.metadata, recordings);
      if (!timeline || !hasAudioCoverage(segments, timeline)) return {
        status: "unavailable", transcriptId: transcript.id, transcriptVersion: transcript.version, reason: "recording_audio_missing",
      };
      return calculate(transcript.id, transcript.version, segments, timeline);
    });
  }
}

async function listAllRecordings(list: (meetingId: string, after: number, limit: number) => Promise<RecordingRecord[]>, meetingId: string) {
  const records: RecordingRecord[] = [];
  let after = 0;
  while (true) {
    const page = await list(meetingId, after, 200);
    records.push(...page);
    if (page.length < 200) return records;
    after = page.at(-1)!.number;
  }
}

function recordingTimeline(metadata: TranscriptMetadata | null, records: RecordingRecord[]): RecordingTimeline[] | undefined {
  if (!metadata) return;
  const selected = new Map<number, { record: RecordingRecord; sources: Set<RecordingSource> }>();
  const add = (record: RecordingRecord, source: RecordingSource) => {
    const item = selected.get(record.number) ?? { record, sources: new Set<RecordingSource>() };
    item.sources.add(source);
    selected.set(record.number, item);
  };
  for (const run of metadata.runs) {
    if (run.generatedBy === "desktop") {
      const record = run.recordingSessionId && records.find(({ sessionId }) => sessionId === run.recordingSessionId!.toLowerCase());
      if (!record) return;
      const recordedSources = sources.filter((source) => record.audio[source] !== undefined);
      if (!recordedSources.length || recordedSources.some((source) => !isAvailable(record.audio[source]))) return;
      for (const source of recordedSources) add(record, source);
      continue;
    }
    if (!run.audioInputs?.length) return;
    for (const input of run.audioInputs) {
      const record = records.find(({ number }) => number === input.recordingNumber);
      const track = record?.audio[input.source];
      if (!record || !isAvailable(track) || track.checksum !== input.checksum) return;
      add(record, input.source);
    }
  }
  let offset = 0;
  return [...selected.values()].sort((left, right) => left.record.number - right.record.number).map(({ record, sources }) => {
    const duration = Math.max(0, (record.endedAt.getTime() - record.startedAt.getTime()) / 1000);
    const item = { record, offset, duration, sources };
    offset += duration;
    return item;
  });
}

function isAvailable(audio: RecordingAudio | undefined): audio is RecordingAudio & { uploadedAt: string; checksum: string } {
  return audio?.active === true && audio.uploadedAt !== null && audio.checksum !== null;
}

function recordingFor(segment: TranscriptAnalyticsSegment, timeline: RecordingTimeline[]): RecordingTimeline | undefined {
  if (!isRecordingSource(segment.audioSource)) return;
  const source = segment.audioSource;
  return timeline.find(({ record, sources: selectedSources }) => {
    const track = record.audio[source];
    return selectedSources.has(source) && isAvailable(track)
      && segment.startedAt >= record.startedAt && segment.startedAt <= record.endedAt;
  });
}

function hasAudioCoverage(segments: TranscriptAnalyticsSegment[], timeline: RecordingTimeline[]): boolean {
  if (!timeline.length) return false;
  return segments.every((segment) => !isRecordingSource(segment.audioSource) || recordingFor(segment, timeline) !== undefined);
}

function calculate(transcriptId: string, transcriptVersion: number, segments: TranscriptAnalyticsSegment[], timeline: RecordingTimeline[]): z.infer<typeof conversationAnalyticsSchema> {
  const accumulators = Object.fromEntries(sources.map((source) => [source, emptyAccumulator()])) as Record<RecordingSource, Accumulator>;
  for (const segment of segments) {
    if (!isRecordingSource(segment.audioSource)) continue;
    const accumulator = accumulators[segment.audioSource];
    accumulator.segmentCount++;
    accumulator.normalizedCharacterCount += segment.normalizedCharacterCount;
    const recording = recordingFor(segment, timeline);
    const interval = recording && segment.endedAt ? segmentInterval(segment, recording) : undefined;
    if (!interval) accumulator.unmeasurableSegmentCount++;
    else {
      accumulator.intervals.push(interval);
      accumulator.timedSegments.push({ interval, normalizedCharacterCount: segment.normalizedCharacterCount });
    }
  }
  const mergedBySource = Object.fromEntries(sources.map((source) => [source, merged(accumulators[source].intervals, SPEECH_MERGE_GAP)])) as Record<RecordingSource, Interval[]>;
  const allIntervals = merged([...mergedBySource.mic, ...mergedBySource.system]);
  const overlapIntervals = intersections(mergedBySource.mic, mergedBySource.system);
  const recordingDuration = timeline.reduce((total, item) => total + item.duration, 0);
  const unionSpeechDuration = duration(allIntervals);
  const overlapDuration = duration(overlapIntervals);
  const timelineDuration = Math.max(recordingDuration, allIntervals.at(-1)?.end ?? 0);
  const totalSourceSpeechDuration = duration(mergedBySource.mic) + duration(mergedBySource.system);
  const sourceMetrics = sources.map((source) => {
    const accumulator = accumulators[source];
    const speechDuration = duration(mergedBySource[source]);
    return { source, speechDuration, normalizedCharacterCount: accumulator.normalizedCharacterCount,
      segmentCount: accumulator.segmentCount, unmeasurableSegmentCount: accumulator.unmeasurableSegmentCount,
      charactersPerMinute: ratio(accumulator.normalizedCharacterCount * 60, speechDuration),
      speechShare: ratio(speechDuration, totalSourceSpeechDuration) };
  });
  let isTimelineCondensed = false;
  const timelineIntervals = sources.flatMap((source) => {
    const display = displayIntervals(mergedBySource[source], timelineDuration);
    isTimelineCondensed ||= display.condensed;
    return display.intervals.map((interval) => ({ source, ...interval }));
  });
  const overlapDisplay = displayIntervals(overlapIntervals, timelineDuration);
  isTimelineCondensed ||= overlapDisplay.condensed;
  const paceBucketDuration = paceBucket(timelineDuration);
  return { status: "ready", transcriptId, transcriptVersion, calculationVersion: CONVERSATION_ANALYTICS_VERSION,
    recordingDuration, unionSpeechDuration, overlapDuration,
    conversationOccupancyRatio: ratio(unionSpeechDuration, recordingDuration), overlapRatio: ratio(overlapDuration, unionSpeechDuration),
    speechMergeGap: SPEECH_MERGE_GAP, monologueMergeGap: MONOLOGUE_MERGE_GAP, sources: sourceMetrics,
    longestMonologue: longestMonologue(accumulators), paceBucketDuration,
    paceSamples: paceSamples(accumulators, mergedBySource, timelineDuration, paceBucketDuration),
    timelineIntervals, overlapIntervals: overlapDisplay.intervals, overlapCount: overlapIntervals.length, isTimelineCondensed };
}

function emptyAccumulator(): Accumulator {
  return { intervals: [], timedSegments: [], normalizedCharacterCount: 0, segmentCount: 0, unmeasurableSegmentCount: 0 };
}

function segmentInterval(segment: TranscriptAnalyticsSegment, recording: RecordingTimeline): Interval | undefined {
  const start = Math.min(Math.max(recording.offset + (segment.startedAt.getTime() - recording.record.startedAt.getTime()) / 1000, recording.offset), recording.offset + recording.duration);
  const end = Math.min(Math.max(recording.offset + (segment.endedAt!.getTime() - recording.record.startedAt.getTime()) / 1000, recording.offset), recording.offset + recording.duration);
  return Number.isFinite(start) && Number.isFinite(end) && end > start ? { start, end } : undefined;
}

function merged(intervals: Interval[], mergeGap = 0): Interval[] {
  const sorted = [...intervals].sort((left, right) => left.start - right.start || left.end - right.end);
  const first = sorted.shift();
  if (!first) return [];
  const result: Interval[] = [];
  let current = first;
  for (const interval of sorted) {
    if (interval.start <= current.end + mergeGap) current = { start: current.start, end: Math.max(current.end, interval.end) };
    else { result.push(current); current = interval; }
  }
  result.push(current);
  return result;
}

function intersections(left: Interval[], right: Interval[]): Interval[] {
  const result: Interval[] = [];
  let leftIndex = 0; let rightIndex = 0;
  while (leftIndex < left.length && rightIndex < right.length) {
    const start = Math.max(left[leftIndex]!.start, right[rightIndex]!.start);
    const end = Math.min(left[leftIndex]!.end, right[rightIndex]!.end);
    if (end > start) result.push({ start, end });
    if (left[leftIndex]!.end <= right[rightIndex]!.end) leftIndex++; else rightIndex++;
  }
  return result;
}

function duration(intervals: Interval[]): number { return intervals.reduce((total, interval) => total + interval.end - interval.start, 0); }
function ratio(numerator: number, denominator: number): number | null { return denominator > 0 ? numerator / denominator : null; }
function overlap(interval: Interval, target: Interval): number { return Math.max(0, Math.min(interval.end, target.end) - Math.max(interval.start, target.start)); }

function longestMonologue(accumulators: Record<RecordingSource, Accumulator>) {
  const candidates = sources.flatMap((source) => merged(accumulators[source].intervals, MONOLOGUE_MERGE_GAP).map((interval) => ({ source, ...interval })));
  return candidates.sort((left, right) => (right.end - right.start) - (left.end - left.start) || left.start - right.start || (left.source === "mic" ? -1 : 1))[0] ?? null;
}

function paceBucket(timelineDuration: number): number {
  if (!Number.isFinite(timelineDuration) || timelineDuration <= 0) return MIN_PACE_BUCKET_DURATION;
  return Math.max(MIN_PACE_BUCKET_DURATION, Math.ceil(timelineDuration / MAX_PACE_SAMPLES / MIN_PACE_BUCKET_DURATION) * MIN_PACE_BUCKET_DURATION);
}

function paceSamples(accumulators: Record<RecordingSource, Accumulator>, speech: Record<RecordingSource, Interval[]>, timelineDuration: number, bucketDuration: number) {
  if (!Number.isFinite(timelineDuration) || timelineDuration <= 0) return [];
  const bucketCount = Math.min(MAX_PACE_SAMPLES, Math.ceil(timelineDuration / bucketDuration));
  return sources.flatMap((source) => {
    let seriesIndex = -1; let previousHadSpeech = false;
    return Array.from({ length: bucketCount }, (_, index) => {
      const bucket = { start: index * bucketDuration, end: Math.min((index + 1) * bucketDuration, timelineDuration) };
      const speechDuration = speech[source].reduce((total, interval) => total + overlap(interval, bucket), 0);
      if (speechDuration <= 0) { previousHadSpeech = false; return null; }
      if (!previousHadSpeech) seriesIndex++;
      previousHadSpeech = true;
      const characters = accumulators[source].timedSegments.reduce((total, segment) =>
        total + segment.normalizedCharacterCount * overlap(segment.interval, bucket) / (segment.interval.end - segment.interval.start), 0);
      return { source, start: bucket.start, end: bucket.end, charactersPerMinute: characters / speechDuration * 60, seriesIndex };
    }).filter((sample) => sample !== null);
  });
}

function displayIntervals(intervals: Interval[], timelineDuration: number): { intervals: Interval[]; condensed: boolean } {
  if (intervals.length <= MAX_TIMELINE_INTERVALS || timelineDuration <= 0) return { intervals, condensed: false };
  const bucketDuration = timelineDuration / MAX_TIMELINE_INTERVALS;
  return { intervals: merged(intervals.map((interval) => {
    const start = Math.floor(interval.start / bucketDuration) * bucketDuration;
    return { start, end: Math.min(timelineDuration, Math.max(Math.ceil(interval.end / bucketDuration) * bucketDuration, start + bucketDuration)) };
  })), condensed: true };
}
