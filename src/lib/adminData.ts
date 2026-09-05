/**
 * Data access for the researcher admin surfaces built in Phase 3:
 * RatingQueue, ParticipantsView, HealthView. All three are read/write only
 * for an allowlisted researcher (RLS enforces this on every table below) —
 * this file does no authorization of its own beyond what the queries already
 * require.
 *
 * Queries are done as several flat selects + client-side joins rather than
 * nested PostgREST embeds, deliberately: the schema has more than one FK path
 * between some of these tables (e.g. responses -> sessions -> participants),
 * and an ambiguous embed either needs a relationship hint that becomes stale
 * the moment a second FK is added, or fails outright. A few extra round trips
 * to an internal researcher tool with no real-time requirement is a fine
 * trade for not maintaining that.
 */

import { supabase } from './supabaseClient';
import { signedUrl, AUDIO_BUCKET } from './media';

function fail(context: string, error: { message: string; code?: string } | null): never {
  throw new Error(`${context}: ${error?.code ? `${error.code} ` : ''}${error?.message ?? 'unknown error'}`);
}

function indexBy<T, K extends string | number>(rows: T[], key: (row: T) => K): Map<K, T> {
  const map = new Map<K, T>();
  for (const row of rows) map.set(key(row), row);
  return map;
}

// ---------------------------------------------------------------- rating queue

/** A reviewer's judgment on one recording. NULL/absent = not yet reviewed,
 * which is deliberately distinct from 'unclear' (reviewed, but unusable). */
export type AudioVerdict = 'correct' | 'incorrect' | 'unclear';

export type RatingQueueRow = {
  audioId: string;
  responseId: string;
  storagePath: string;
  mimeType: string | null;
  durationMs: number | null;
  ratingStatus: string;
  isReliabilitySubsample: boolean;
  notes: string | null;
  verdict: AudioVerdict | null;
  primaryRating: boolean | null;
  itemCode: string;
  stimulusText: string | null;
  correctAnswer: string | null;
  domain: string;
  subdomain: string | null;
  participantId: string | null;
  anonymizedCode: string | null;
  classGrade: number | null;
  uploadedAt: string;
};

export type RecordingFilter = {
  /** Include recordings already reviewed. Ignored when `participantId` is set:
   * a single participant's page always shows every recording of theirs. */
  includeRated?: boolean;
  participantId?: string;
};

/** Every response id belonging to one participant, across their session(s). */
async function responseIdsForParticipant(participantId: string): Promise<string[]> {
  const { data: sessions, error: sessErr } = await supabase
    .from('sessions')
    .select('id')
    .eq('participant_id', participantId);
  if (sessErr) fail('Could not load sessions for the participant', sessErr);

  const sessionIds = (sessions ?? []).map((s) => s.id);
  if (sessionIds.length === 0) return [];

  const { data: responses, error: respErr } = await supabase
    .from('responses')
    .select('id')
    .in('session_id', sessionIds);
  if (respErr) fail('Could not load responses for the participant', respErr);
  return (responses ?? []).map((r) => r.id);
}

/** Thin wrapper kept for the Rating Queue's own call site. */
export function listRatingQueue(includeRated: boolean): Promise<RatingQueueRow[]> {
  return listRecordings({ includeRated });
}

/**
 * Audio recordings with everything a reviewer needs to judge one: the item it
 * answers, that item's reference answer, and which participant produced it.
 * Backs both the Rating Queue (all pending work) and a single participant's
 * recordings panel (`participantId`).
 */
export async function listRecordings(filter: RecordingFilter = {}): Promise<RatingQueueRow[]> {
  let query = supabase
    .from('audio_recordings')
    .select(
      'id, response_id, storage_path, mime_type, duration_ms, rating_status, is_reliability_subsample, notes, primary_rating, primary_verdict, uploaded_at',
    )
    .order('uploaded_at', { ascending: true });

  if (filter.participantId) {
    const ids = await responseIdsForParticipant(filter.participantId);
    if (ids.length === 0) return [];
    query = query.in('response_id', ids);
  } else if (!filter.includeRated) {
    query = query.eq('rating_status', 'pending');
  }

  const { data: recordings, error } = await query;
  if (error) fail('Could not load the rating queue', error);
  if (!recordings || recordings.length === 0) return [];

  const responseIds = [...new Set(recordings.map((r) => r.response_id))];
  const { data: responses, error: respErr } = await supabase
    .from('responses')
    .select('id, session_id, item_id')
    .in('id', responseIds);
  if (respErr) fail('Could not load responses for the rating queue', respErr);

  const itemIds = [...new Set((responses ?? []).map((r) => r.item_id))];
  const sessionIds = [...new Set((responses ?? []).map((r) => r.session_id))];

  const [{ data: items, error: itemErr }, { data: sessions, error: sessErr }] = await Promise.all([
    supabase
      .from('items')
      .select('id, item_code, stimulus_text, correct_answer, domain, subdomain')
      .in('id', itemIds),
    supabase.from('sessions').select('id, participant_id').in('id', sessionIds),
  ]);
  if (itemErr) fail('Could not load items for the rating queue', itemErr);
  if (sessErr) fail('Could not load sessions for the rating queue', sessErr);

  const participantIds = [...new Set((sessions ?? []).map((s) => s.participant_id).filter((v): v is string => !!v))];
  const { data: participants, error: partErr } =
    participantIds.length > 0
      ? await supabase.from('participants').select('id, anonymized_code, class_grade').in('id', participantIds)
      : { data: [], error: null };
  if (partErr) fail('Could not load participants for the rating queue', partErr);

  const responseById = indexBy(responses ?? [], (r) => r.id);
  const itemById = indexBy(items ?? [], (i) => i.id);
  const sessionById = indexBy(sessions ?? [], (s) => s.id);
  const participantById = indexBy(participants ?? [], (p) => p.id);

  return recordings.map((r) => {
    const response = responseById.get(r.response_id);
    const item = response ? itemById.get(response.item_id) : undefined;
    const session = response ? sessionById.get(response.session_id) : undefined;
    const participant = session?.participant_id ? participantById.get(session.participant_id) : undefined;
    return {
      audioId: r.id,
      responseId: r.response_id,
      storagePath: r.storage_path,
      mimeType: r.mime_type,
      durationMs: r.duration_ms,
      ratingStatus: r.rating_status,
      isReliabilitySubsample: r.is_reliability_subsample,
      notes: r.notes,
      verdict: (r.primary_verdict as AudioVerdict | null) ?? null,
      primaryRating: r.primary_rating,
      itemCode: item?.item_code ?? '(unknown item)',
      stimulusText: item?.stimulus_text ?? null,
      correctAnswer: item?.correct_answer ?? null,
      domain: item?.domain ?? '?',
      subdomain: item?.subdomain ?? null,
      participantId: session?.participant_id ?? null,
      anonymizedCode: participant?.anonymized_code ?? null,
      classGrade: participant?.class_grade ?? null,
      uploadedAt: r.uploaded_at,
    };
  });
}

export function signedRatingAudioUrl(storagePath: string): Promise<string> {
  return signedUrl(AUDIO_BUCKET, storagePath, 300);
}

/**
 * Records a reviewer's free-text note and marks the recording reviewed. Never
 * touches `responses.is_correct` — see submitPrimaryRating's doc comment for
 * why that stays NULL regardless of anything set here.
 */
export async function saveRecordingNotes(audioId: string, notes: string, raterId: string): Promise<void> {
  const { error } = await supabase
    .from('audio_recordings')
    .update({
      notes: notes.trim() || null,
      primary_rater_id: raterId,
      primary_rated_at: new Date().toISOString(),
      rating_status: 'rated',
    })
    .eq('id', audioId);
  if (error) fail('Could not save the note', error);
}

/**
 * Records a researcher's correct/incorrect judgment on `audio_recordings.primary_rating`.
 *
 * CHANGED IN MIGRATION 0010, RESTORED IN MIGRATION 0013: this used to propagate onto
 * `responses.is_correct` via the `propagate_audio_rating` trigger (migration 0001), which
 * was neutered in 0010 when the decision became "correctness is decided later by an
 * offline model against the raw audio, not a human's live click." That decision on
 * `responses.is_correct` is UNCHANGED — this function still never touches `responses`.
 * What changed back: the user wants this judgment available as its own column (alongside
 * a playable URL) in the full CSV export, so researchers reviewing the export can see
 * both without needing the model's output yet. `primary_rating` was always still in the
 * schema, just unused by the UI between 0010 and 0013.
 */
export async function submitAudioVerdict(
  audioId: string,
  verdict: AudioVerdict,
  raterId: string,
): Promise<void> {
  const { error } = await supabase
    .from('audio_recordings')
    .update({
      primary_verdict: verdict,
      // Two-state projection kept in sync so the long-standing export column
      // `audio_marked_correct` keeps its meaning. 'unclear' has no boolean
      // equivalent, so it lands as NULL there and is only distinguishable via
      // `audio_review_verdict` (migration 0021).
      primary_rating: verdict === 'correct' ? true : verdict === 'incorrect' ? false : null,
      primary_rater_id: raterId,
      primary_rated_at: new Date().toISOString(),
      rating_status: 'rated',
    })
    .eq('id', audioId);
  if (error) fail('Could not save the verdict', error);
}

/**
 * Manual OVERRIDE on top of submit_session()'s automatic random assignment
 * (migration 0008, reliability_subsample_rate()). Not the primary mechanism —
 * the baseline sample must stay unbiased by construction, so this exists for
 * legitimate one-off cases (forcing a specific recording into the double-
 * scored set), not for routinely curating which recordings get double-scored.
 */
export async function setReliabilitySubsample(audioId: string, value: boolean): Promise<void> {
  const { error } = await supabase.from('audio_recordings').update({ is_reliability_subsample: value }).eq('id', audioId);
  if (error) fail('Could not update the reliability-subsample flag', error);
}

// ---------------------------------------------------------------- participants

export type ParticipantRow = {
  id: string;
  anonymizedCode: string;
  classGrade: number | null;
  ageMonths: number | null;
  createdAt: string;
  sessionStatus: string | null;
  responseCount: number;
  /** Audio recordings this participant produced, and how many still need review. */
  recordingCount: number;
  recordingsPending: number;
};

export async function listParticipants(): Promise<ParticipantRow[]> {
  const { data: participants, error } = await supabase
    .from('participants')
    .select('id, anonymized_code, class_grade, age_months, created_at')
    .order('created_at', { ascending: false });
  if (error) fail('Could not load participants', error);
  if (!participants || participants.length === 0) return [];

  const ids = participants.map((p) => p.id);
  const { data: sessions, error: sessErr } = await supabase
    .from('sessions')
    .select('id, participant_id, status')
    .in('participant_id', ids);
  if (sessErr) fail('Could not load sessions for participants', sessErr);

  const sessionIds = (sessions ?? []).map((s) => s.id);
  const { data: responses, error: respErr } =
    sessionIds.length > 0
      ? await supabase.from('responses').select('id, session_id').in('session_id', sessionIds)
      : { data: [], error: null };
  if (respErr) fail('Could not load responses for participants', respErr);

  // Recording counts, so the roster can show who has audio waiting for review.
  const responseIds = (responses ?? []).map((r) => r.id);
  const { data: recordings, error: recErr } =
    responseIds.length > 0
      ? await supabase.from('audio_recordings').select('response_id, rating_status').in('response_id', responseIds)
      : { data: [], error: null };
  if (recErr) fail('Could not load recordings for participants', recErr);

  const sessionByResponse = new Map<string, string>();
  for (const r of responses ?? []) sessionByResponse.set(r.id, r.session_id);

  const sessionByParticipant = indexBy(sessions ?? [], (s) => s.participant_id as string);
  const responseCountBySession = new Map<string, number>();
  for (const r of responses ?? []) {
    responseCountBySession.set(r.session_id, (responseCountBySession.get(r.session_id) ?? 0) + 1);
  }

  const recTotalBySession = new Map<string, number>();
  const recPendingBySession = new Map<string, number>();
  for (const rec of recordings ?? []) {
    const sid = sessionByResponse.get(rec.response_id);
    if (!sid) continue;
    recTotalBySession.set(sid, (recTotalBySession.get(sid) ?? 0) + 1);
    if (rec.rating_status === 'pending') {
      recPendingBySession.set(sid, (recPendingBySession.get(sid) ?? 0) + 1);
    }
  }

  return participants.map((p) => {
    const session = sessionByParticipant.get(p.id);
    return {
      id: p.id,
      anonymizedCode: p.anonymized_code,
      classGrade: p.class_grade,
      ageMonths: p.age_months,
      createdAt: p.created_at,
      sessionStatus: session?.status ?? null,
      responseCount: session ? (responseCountBySession.get(session.id) ?? 0) : 0,
      recordingCount: session ? (recTotalBySession.get(session.id) ?? 0) : 0,
      recordingsPending: session ? (recPendingBySession.get(session.id) ?? 0) : 0,
    };
  });
}

// ---------------------------------------------------------------- health

export type HealthSummary = {
  sessionsInProgress: number;
  sessionsCompleted: number;
  recordingsPending: number;
  recordingsRated: number;
  itemsMissingAudio: number;
  itemsActiveTotal: number;
};

export async function getHealthSummary(): Promise<HealthSummary> {
  const [
    { count: inProgress, error: e1 },
    { count: completed, error: e2 },
    { count: pending, error: e3 },
    { count: rated, error: e4 },
    { data: activeItems, error: e5 },
  ] = await Promise.all([
    supabase.from('sessions').select('id', { count: 'exact', head: true }).eq('status', 'in_progress'),
    supabase.from('sessions').select('id', { count: 'exact', head: true }).eq('status', 'completed'),
    supabase.from('audio_recordings').select('id', { count: 'exact', head: true }).eq('rating_status', 'pending'),
    supabase.from('audio_recordings').select('id', { count: 'exact', head: true }).eq('rating_status', 'rated'),
    supabase.from('items').select('instruction_audio_path, stimulus_audio_path').eq('active', true),
  ]);
  for (const e of [e1, e2, e3, e4, e5]) if (e) fail('Could not load the health summary', e);

  const itemsMissingAudio = (activeItems ?? []).filter(
    (i) => !i.instruction_audio_path && !i.stimulus_audio_path,
  ).length;

  return {
    sessionsInProgress: inProgress ?? 0,
    sessionsCompleted: completed ?? 0,
    recordingsPending: pending ?? 0,
    recordingsRated: rated ?? 0,
    itemsMissingAudio,
    itemsActiveTotal: activeItems?.length ?? 0,
  };
}

// ---------------------------------------------------------------- full raw-data export

const EXPORT_PAGE_SIZE = 1000; // PostgREST's default row cap per request.

/**
 * Every raw column collected about every participant, one row per response —
 * `full_export_v1` (migration 0011). Paginated because a real dataset can
 * exceed PostgREST's default 1000-row response cap; a plain `.select('*')`
 * would silently truncate rather than error.
 */
async function fetchFullExportRows(): Promise<Record<string, unknown>[]> {
  const rows: Record<string, unknown>[] = [];
  for (let from = 0; ; from += EXPORT_PAGE_SIZE) {
    const { data, error } = await supabase
      .from('full_export_v1')
      .select('*')
      .range(from, from + EXPORT_PAGE_SIZE - 1);
    if (error) fail('Could not load the export data', error);
    if (!data || data.length === 0) break;
    rows.push(...(data as Record<string, unknown>[]));
    if (data.length < EXPORT_PAGE_SIZE) break;
  }
  return rows;
}

function csvEscape(value: unknown): string {
  if (value === null || value === undefined) return '';
  const s = typeof value === 'boolean' ? (value ? 'true' : 'false') : String(value);
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

// A CSV gets opened well after it's downloaded, not immediately — a short-lived signed
// URL (the app's normal 300s/3600s playback links) would already be dead by then. 30
// days is a reasonable "download and use soon" window for a manual export action.
/**
 * Lifetime of the playable audio links written into the CSV.
 *
 * Supabase documents no maximum for `expiresIn`, and storage signing uses a
 * dedicated key that survives Auth key rotation, so a long window is
 * technically safe. The real cost is privacy, not mechanics: each link is a
 * bearer token to a child's voice recording, it cannot be revoked without
 * contacting Supabase support, and expiring a token does not purge the CDN
 * copy — deleting the object is the only hard cut-off. `audio_storage_path`
 * is exported alongside, so links can always be regenerated after expiry.
 */
const EXPORT_AUDIO_URL_EXPIRY_SECONDS = 60 * 60 * 24 * 90;

/**
 * Fetches the entire raw dataset and triggers a CSV file download in the
 * browser. No server-side export function exists (or is needed) — this is a
 * researcher-only, occasional, whole-table download, not a live feature.
 *
 * Each row with an audio response gets a real, playable `audio_url` column —
 * a CSV is text-only, so it can't embed the file itself, but a long-lived
 * signed URL lets a researcher actually open the recording from the sheet.
 */
export async function downloadFullExportCsv(): Promise<number> {
  const rows = await fetchFullExportRows();
  if (rows.length === 0) return 0;

  await Promise.all(
    rows.map(async (row) => {
      const path = row.audio_storage_path as string | null;
      row.audio_url = path
        ? await signedUrl(AUDIO_BUCKET, path, EXPORT_AUDIO_URL_EXPIRY_SECONDS).catch(() => null)
        : null;
    }),
  );

  triggerCsvDownload(rows, 'badsq-full-export');
  return rows.length;
}

/**
 * Serialize rows to CSV and hand them to the browser as a download.
 *
 * Headers come from the first row's keys — safe here because every row of a
 * given export originates from the same view, so the key set is identical
 * across rows.
 */
function triggerCsvDownload(rows: Record<string, unknown>[], filenamePrefix: string): void {
  const headers = Object.keys(rows[0]);
  const lines = [headers.join(',')];
  for (const row of rows) {
    lines.push(headers.map((h) => csvEscape(row[h])).join(','));
  }

  const blob = new Blob([lines.join('\r\n')], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  try {
    const a = document.createElement('a');
    a.href = url;
    a.download = `${filenamePrefix}-${new Date().toISOString().slice(0, 10)}.csv`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
  } finally {
    URL.revokeObjectURL(url);
  }
}

/**
 * Per-participant summary export — one row per participant (participant_summary_v1).
 *
 * Companion to downloadFullExportCsv()'s per-response file, not a replacement:
 * same underlying data at a coarser grain, for visualisation and
 * cross-participant comparison. Carries no audio URLs, since a participant row
 * summarises many recordings rather than pointing at one.
 */
export async function downloadParticipantSummaryCsv(): Promise<number> {
  const rows: Record<string, unknown>[] = [];
  for (let from = 0; ; from += EXPORT_PAGE_SIZE) {
    const { data, error } = await supabase
      .from('participant_summary_v1')
      .select('*')
      .range(from, from + EXPORT_PAGE_SIZE - 1);
    if (error) fail('Could not load the participant summary', error);
    if (!data || data.length === 0) break;
    rows.push(...(data as Record<string, unknown>[]));
    if (data.length < EXPORT_PAGE_SIZE) break;
  }
  if (rows.length === 0) return 0;

  triggerCsvDownload(rows, 'badsq-participant-summary');
  return rows.length;
}
