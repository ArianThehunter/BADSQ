/**
 * Item bank data access.
 *
 * The versioning rule is the important part and lives here rather than in the
 * component: editing an item NEVER mutates the row a completed session already
 * answered. It writes a NEW row with version + 1 and retires the previous one
 * (active = false). `responses.item_id` keeps pointing at the exact version the
 * student was shown, which is what makes retired versions correct rather than a
 * defect — a session must score against what it actually presented.
 *
 * "Delete" is always soft: active = false, never a DELETE.
 */

import { supabase, AUDIO_BUCKET } from './supabaseClient';
import { activationBlockers } from './itemValidation';
import type { DraftItem, DraftOption, ResponseFormat, ScoringMode } from './itemValidation';

export const ITEM_AUDIO_BUCKET = 'badsq-item-audio';
export { AUDIO_BUCKET };

export type ItemRow = {
  id: string;
  item_code: string;
  version: number;
  domain: string;
  subdomain: string | null;
  response_format: ResponseFormat;
  scoring_mode: ScoringMode;
  correct_answer: string | null;
  stimulus_text: string | null;
  instruction_audio_path: string | null;
  stimulus_audio_path: string | null;
  is_instruction_replayable: boolean;
  is_stimulus_replayable: boolean | null;
  is_practice: boolean;
  is_scored: boolean;
  display_order: number | null;
  active: boolean;
  created_at: string;
};

export type OptionRow = DraftOption & { id: string; item_id: string };

// NOTE: this must be ONE string literal, not built with `+`. The `+` operator
// widens even literal operands to `string`, which defeats supabase-js's
// compile-time parsing of the select list and silently falls back to an
// untyped `GenericStringError` result — caught here, not worth re-discovering.
const ITEM_COLUMNS =
  'id, item_code, version, domain, subdomain, response_format, scoring_mode, correct_answer, stimulus_text, instruction_audio_path, stimulus_audio_path, is_instruction_replayable, is_stimulus_replayable, is_practice, is_scored, display_order, active, created_at';

function fail(context: string, error: { message: string; code?: string } | null): never {
  throw new Error(`${context}: ${error?.code ? `${error.code} ` : ''}${error?.message ?? 'unknown error'}`);
}

/** All items, newest version of each code first. Researchers only (RLS). */
export async function listItems(opts?: { domain?: string; includeRetired?: boolean }): Promise<ItemRow[]> {
  let q = supabase.from('items').select(ITEM_COLUMNS);
  if (opts?.domain) q = q.eq('domain', opts.domain);
  if (!opts?.includeRetired) q = q.eq('active', true);

  const { data, error } = await q
    .order('display_order', { ascending: true, nullsFirst: false })
    .order('item_code', { ascending: true })
    .order('version', { ascending: false });

  if (error) fail('Could not load items', error);
  return (data ?? []) as ItemRow[];
}

export async function listOptions(itemId: string): Promise<OptionRow[]> {
  const { data, error } = await supabase
    .from('item_options')
    .select('id, item_id, option_key, option_text, is_correct')
    .eq('item_id', itemId)
    .order('option_key', { ascending: true });
  if (error) fail('Could not load options', error);
  return (data ?? []) as OptionRow[];
}

/** Distinct domains present, for the filter control. */
export async function listDomains(): Promise<string[]> {
  const { data, error } = await supabase.from('items').select('domain');
  if (error) fail('Could not load domains', error);
  return [...new Set((data ?? []).map((r) => (r as { domain: string }).domain))].sort();
}

function itemPayload(draft: DraftItem, version: number, active: boolean) {
  return {
    item_code: draft.item_code.trim(),
    version,
    domain: draft.domain.trim(),
    subdomain: draft.subdomain?.trim() || null,
    response_format: draft.response_format,
    scoring_mode: draft.scoring_mode,
    correct_answer: draft.correct_answer?.trim() || null,
    stimulus_text: draft.stimulus_text?.trim() || null,
    instruction_audio_path: draft.instruction_audio_path || null,
    stimulus_audio_path: draft.stimulus_audio_path || null,
    is_instruction_replayable: draft.is_instruction_replayable,
    is_stimulus_replayable: draft.is_stimulus_replayable,
    is_practice: draft.is_practice,
    is_scored: draft.is_scored,
    display_order: draft.display_order,
    active,
  };
}

async function writeOptions(itemId: string, options: DraftOption[]): Promise<void> {
  if (options.length === 0) return;
  const { error } = await supabase.from('item_options').insert(
    options.map((o) => ({
      item_id: itemId,
      option_key: o.option_key.trim(),
      option_text: o.option_text,
      is_correct: o.is_correct,
    })),
  );
  if (error) fail('Could not write options', error);
}

/** Highest version currently recorded for an item_code, or 0 if none. */
export async function highestVersion(itemCode: string): Promise<number> {
  const { data, error } = await supabase
    .from('items')
    .select('version')
    .eq('item_code', itemCode.trim())
    .order('version', { ascending: false })
    .limit(1);
  if (error) fail('Could not read current version', error);
  return data && data.length > 0 ? (data[0] as { version: number }).version : 0;
}

/** Create version 1 of a brand-new item code. */
export async function createItem(draft: DraftItem, active: boolean): Promise<ItemRow> {
  const existing = await highestVersion(draft.item_code);
  if (existing > 0) {
    throw new Error(
      `Item code "${draft.item_code}" already exists (highest version ${existing}). ` +
        'Edit that item instead — editing creates the next version.',
    );
  }
  const { data, error } = await supabase
    .from('items')
    .insert(itemPayload(draft, 1, active))
    .select(ITEM_COLUMNS)
    .single();
  if (error) fail('Could not create item', error);

  const row = data as ItemRow;
  await writeOptions(row.id, draft.options);
  return row;
}

/**
 * Save an edit as a NEW version, retiring the previous row.
 *
 * NOT atomic — there is no server-side RPC for this, so it is three statements.
 * The ordering is chosen so the failure modes are recoverable and visible:
 *   1. insert the new version (inactive)   — a failure here changes nothing
 *   2. copy the options across             — a failure leaves an inactive,
 *                                            option-less draft, which the
 *                                            activation guard refuses to publish
 *   3. retire the old version, activate the new one
 * A crash between 2 and 3 leaves BOTH versions inactive rather than both active,
 * so participants never see a duplicated item. See PHASE_1_REPORT.md.
 */
export async function saveNewVersion(
  previous: ItemRow,
  draft: DraftItem,
  active: boolean,
): Promise<ItemRow> {
  const next = (await highestVersion(draft.item_code)) + 1;

  const { data, error } = await supabase
    .from('items')
    .insert(itemPayload(draft, next, false))
    .select(ITEM_COLUMNS)
    .single();
  if (error) fail('Could not create the new version', error);
  const row = data as ItemRow;

  await writeOptions(row.id, draft.options);

  const { error: retireErr } = await supabase
    .from('items')
    .update({ active: false })
    .eq('id', previous.id);
  if (retireErr) fail('Created the new version but could not retire the previous one', retireErr);

  if (active) {
    const { error: activateErr } = await supabase
      .from('items')
      .update({ active: true })
      .eq('id', row.id);
    if (activateErr) fail('Retired the previous version but could not activate the new one', activateErr);
    row.active = true;
  }
  return row;
}

/** Soft delete. Never a hard DELETE — completed sessions reference this row. */
export async function retireItem(itemId: string): Promise<void> {
  const { error } = await supabase.from('items').update({ active: false }).eq('id', itemId);
  if (error) fail('Could not retire item', error);
}

export async function setActive(itemId: string, active: boolean): Promise<void> {
  const { error } = await supabase.from('items').update({ active }).eq('id', itemId);
  if (error) fail(active ? 'Could not activate item' : 'Could not deactivate item', error);
}

/* ------------------------------------------------------------------ audio */

/**
 * Upload item audio and return its storage OBJECT PATH (not a URL).
 *
 * `items.instruction_audio_path` / `stimulus_audio_path` store the path; the
 * bucket is private, so playback needs a short-lived signed URL. Item audio
 * reveals test content, which is why the bucket is not public.
 */
export async function uploadItemAudio(
  file: File,
  itemCode: string,
  kind: 'instruction' | 'stimulus',
): Promise<string> {
  const safeCode = itemCode.trim().replace(/[^A-Za-z0-9._-]/g, '_') || 'untitled';
  const ext = (file.name.split('.').pop() || 'bin').toLowerCase().replace(/[^a-z0-9]/g, '');
  // Timestamped so re-uploading never silently overwrites an object a previous
  // item version still points at.
  const path = `${safeCode}/${kind}-${Date.now()}.${ext}`;

  const { error } = await supabase.storage
    .from(ITEM_AUDIO_BUCKET)
    .upload(path, file, { contentType: file.type || undefined, upsert: false });
  if (error) fail('Audio upload failed', error);
  return path;
}

/** Short-lived signed URL so a researcher can hear what they uploaded. */
export async function signedAudioUrl(path: string, expiresInSeconds = 3600): Promise<string> {
  const { data, error } = await supabase.storage
    .from(ITEM_AUDIO_BUCKET)
    .createSignedUrl(path, expiresInSeconds);
  if (error || !data?.signedUrl) fail('Could not sign audio URL', error);
  return data.signedUrl;
}

/* ------------------------------------------------- standing quality checks */

export type QualityFinding = { item_code: string; version: number; issue: string };

/**
 * The design doc section 6 checks, run across the whole live bank rather than
 * one item at a time — the per-item guard only fires when someone opens that
 * item, and these were originally found by a sweep.
 */
export async function itemBankQualitySweep(): Promise<QualityFinding[]> {
  const items = await listItems({ includeRetired: false });
  const findings: QualityFinding[] = [];

  for (const item of items) {
    const options = await listOptions(item.id);
    const blockers = activationBlockers({
      ...item,
      options: options.map((o) => ({
        option_key: o.option_key,
        option_text: o.option_text,
        is_correct: o.is_correct,
      })),
    });
    for (const b of blockers) {
      findings.push({ item_code: item.item_code, version: item.version, issue: b.message });
    }
  }
  return findings;
}
