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

export type RatingQueueRow = {
  audioId: string;
  responseId: string;
  storagePath: string;
  mimeType: string | null;
  durationMs: number | null;
  ratingStatus: string;
  isReliabilitySubsample: boolean;
  notes: string | null;
  itemCode: string;
  stimulusText: string | null;
  domain: string;
  anonymizedCode: string | null;
  classGrade: number | null;
  uploadedAt: string;
};

export async function listRatingQueue(includeRated: boolean): Promise<RatingQueueRow[]> {
  let query = supabase
    .from('audio_recordings')
    .select(
      'id, response_id, storage_path, mime_type, duration_ms, rating_status, is_reliability_subsample, notes, uploaded_at',
    )
    .order('uploaded_at', { ascending: true });
  if (!includeRated) query = query.eq('rating_status', 'pending');

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
    supabase.from('items').select('id, item_code, stimulus_text, domain').in('id', itemIds),
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
      itemCode: item?.item_code ?? '(unknown item)',
      stimulusText: item?.stimulus_text ?? null,
      domain: item?.domain ?? '?',
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
 * Records a reviewer's free-text note and marks the recording reviewed.
 *
 * CHANGED IN MIGRATION 0010: this used to be `submitPrimaryRating(audioId,
 * correct, raterId)`, writing a binary correct/incorrect judgment that the
 * `propagate_audio_rating` trigger copied onto `responses.is_correct`.
 * Decision reversed — correctness for AUDIO_RECORD responses is now decided
 * later by an offline model run against the raw stored audio, not by a
 * human's live binary click, so `is_correct` stays NULL here regardless of
 * what a researcher writes in `notes`. The trigger is neutered accordingly;
 * this function only ever touches `audio_recordings`.
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
      ? await supabase.from('responses').select('session_id').in('session_id', sessionIds)
      : { data: [], error: null };
  if (respErr) fail('Could not load responses for participants', respErr);

  const sessionByParticipant = indexBy(sessions ?? [], (s) => s.participant_id as string);
  const responseCountBySession = new Map<string, number>();
  for (const r of responses ?? []) {
    responseCountBySession.set(r.session_id, (responseCountBySession.get(r.session_id) ?? 0) + 1);
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
